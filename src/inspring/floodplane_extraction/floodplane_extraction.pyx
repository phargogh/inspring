# cython: profile=False
# cython: language_level=3
import collections
import logging
import os
import shutil
import taskgraph
import tempfile
import time

cimport cython
cimport numpy
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cython.operator cimport dereference as deref
from cython.operator cimport preincrement as inc
from libc.time cimport time as ctime
from libc.time cimport time_t
from libcpp.deque cimport deque
from libcpp.list cimport list as clist
from libcpp.pair cimport pair
from libcpp.queue cimport queue
from libcpp.set cimport set as cset
from libcpp.stack cimport stack
from libcpp.vector cimport vector
from osgeo import gdal
from osgeo import ogr
from osgeo import osr
import numpy
import shapely.wkb
import shapely.ops
import scipy.stats

import pygeoprocessing

LOGGER = logging.getLogger(__name__)

# Number of raster blocks to hold in memory at once per Managed Raster
cdef int MANAGED_RASTER_N_BLOCKS = 2**6

# this is a least recently used cache written in C++ in an external file,
# exposing here so _ManagedRaster can use it
cdef extern from "LRUCache.h" nogil:
    cdef cppclass LRUCache[KEY_T, VAL_T]:
        LRUCache(int)
        void put(KEY_T&, VAL_T&, clist[pair[KEY_T,VAL_T]]&)
        clist[pair[KEY_T,VAL_T]].iterator begin()
        clist[pair[KEY_T,VAL_T]].iterator end()
        bint exist(KEY_T &)
        VAL_T get(KEY_T &)
        void clean(clist[pair[KEY_T,VAL_T]]&, int n_items)
        size_t size()


# this ctype is used to store the block ID and the block buffer as one object
# inside Managed Raster
ctypedef pair[int, double*] BlockBufferPair

# a class to allow fast random per-pixel access to a raster for both setting
# and reading pixels.
cdef class _ManagedRaster:
    cdef LRUCache[int, double*]* lru_cache
    cdef cset[int] dirty_blocks
    cdef int block_xsize
    cdef int block_ysize
    cdef int block_xmod
    cdef int block_ymod
    cdef int block_xbits
    cdef int block_ybits
    cdef int raster_x_size
    cdef int raster_y_size
    cdef int block_nx
    cdef int block_ny
    cdef int write_mode
    cdef bytes raster_path
    cdef int band_id
    cdef int closed

    def __cinit__(self, raster_path, band_id, write_mode):
        """Create new instance of Managed Raster.

        Parameters:
            raster_path (char*): path to raster that has block sizes that are
                powers of 2. If not, an exception is raised.
            band_id (int): which band in `raster_path` to index. Uses GDAL
                notation that starts at 1.
            write_mode (boolean): if true, this raster is writable and dirty
                memory blocks will be written back to the raster as blocks
                are swapped out of the cache or when the object deconstructs.

        Returns:
            None.
        """
        if not os.path.isfile(raster_path):
            LOGGER.error("%s is not a file.", raster_path)
            return
        raster_info = pygeoprocessing.get_raster_info(raster_path)
        self.raster_x_size, self.raster_y_size = raster_info['raster_size']
        self.block_xsize, self.block_ysize = raster_info['block_size']
        self.block_xmod = self.block_xsize-1
        self.block_ymod = self.block_ysize-1

        if not (1 <= band_id <= raster_info['n_bands']):
            err_msg = (
                "Error: band ID (%s) is not a valid band number. "
                "This exception is happening in Cython, so it will cause a "
                "hard seg-fault, but it's otherwise meant to be a "
                "ValueError." % (band_id))
            print(err_msg)
            raise ValueError(err_msg)
        self.band_id = band_id

        if (self.block_xsize & (self.block_xsize - 1) != 0) or (
                self.block_ysize & (self.block_ysize - 1) != 0):
            # If inputs are not a power of two, this will at least print
            # an error message. Unfortunately with Cython, the exception will
            # present itself as a hard seg-fault, but I'm leaving the
            # ValueError in here at least for readability.
            err_msg = (
                "Error: Block size is not a power of two: "
                "block_xsize: %d, %d, %s. This exception is happening"
                "in Cython, so it will cause a hard seg-fault, but it's"
                "otherwise meant to be a ValueError." % (
                    self.block_xsize, self.block_ysize, raster_path))
            print(err_msg)
            raise ValueError(err_msg)

        self.block_xbits = numpy.log2(self.block_xsize)
        self.block_ybits = numpy.log2(self.block_ysize)
        self.block_nx = (
            self.raster_x_size + (self.block_xsize) - 1) // self.block_xsize
        self.block_ny = (
            self.raster_y_size + (self.block_ysize) - 1) // self.block_ysize

        self.lru_cache = new LRUCache[int, double*](MANAGED_RASTER_N_BLOCKS)
        self.raster_path = <bytes> raster_path
        self.write_mode = write_mode
        self.closed = 0

    def __dealloc__(self):
        """Deallocate _ManagedRaster.

        This operation manually frees memory from the LRUCache and writes any
        dirty memory blocks back to the raster if `self.write_mode` is True.
        """
        self.close()

    def close(self):
        """Close the _ManagedRaster and free up resources.

            This call writes any dirty blocks to disk, frees up the memory
            allocated as part of the cache, and frees all GDAL references.

            Any subsequent calls to any other functions in _ManagedRaster will
            have undefined behavior.
        """
        if self.closed:
            return
        self.closed = 1
        cdef int xi_copy, yi_copy
        cdef numpy.ndarray[double, ndim=2] block_array = numpy.empty(
            (self.block_ysize, self.block_xsize))
        cdef double *double_buffer
        cdef int block_xi
        cdef int block_yi
        # initially the win size is the same as the block size unless
        # we're at the edge of a raster
        cdef int win_xsize
        cdef int win_ysize

        # we need the offsets to subtract from global indexes for cached array
        cdef int xoff
        cdef int yoff

        cdef clist[BlockBufferPair].iterator it = self.lru_cache.begin()
        cdef clist[BlockBufferPair].iterator end = self.lru_cache.end()
        if not self.write_mode:
            while it != end:
                # write the changed value back if desired
                PyMem_Free(deref(it).second)
                inc(it)
            return

        raster = gdal.OpenEx(
            self.raster_path, gdal.GA_Update | gdal.OF_RASTER)
        raster_band = raster.GetRasterBand(self.band_id)

        # if we get here, we're in write_mode
        cdef cset[int].iterator dirty_itr
        while it != end:
            double_buffer = deref(it).second
            block_index = deref(it).first

            # write to disk if block is dirty
            dirty_itr = self.dirty_blocks.find(block_index)
            if dirty_itr != self.dirty_blocks.end():
                self.dirty_blocks.erase(dirty_itr)
                block_xi = block_index % self.block_nx
                block_yi = block_index / self.block_nx

                # we need the offsets to subtract from global indexes for
                # cached array
                xoff = block_xi << self.block_xbits
                yoff = block_yi << self.block_ybits

                win_xsize = self.block_xsize
                win_ysize = self.block_ysize

                # clip window sizes if necessary
                if xoff+win_xsize > self.raster_x_size:
                    win_xsize = win_xsize - (
                        xoff+win_xsize - self.raster_x_size)
                if yoff+win_ysize > self.raster_y_size:
                    win_ysize = win_ysize - (
                        yoff+win_ysize - self.raster_y_size)

                for xi_copy in range(win_xsize):
                    for yi_copy in range(win_ysize):
                        block_array[yi_copy, xi_copy] = (
                            double_buffer[
                                (yi_copy << self.block_xbits) + xi_copy])
                raster_band.WriteArray(
                    block_array[0:win_ysize, 0:win_xsize],
                    xoff=xoff, yoff=yoff)
            PyMem_Free(double_buffer)
            inc(it)
        raster_band.FlushCache()
        raster_band = None
        raster = None

    cdef inline void set(self, int xi, int yi, double value):
        """Set the pixel at `xi,yi` to `value`."""
        if xi < 0 or xi >= self.raster_x_size:
            LOGGER.error("x out of bounds %s" % xi)
        if yi < 0 or yi >= self.raster_y_size:
            LOGGER.error("y out of bounds %s" % yi)
        cdef int block_xi = xi >> self.block_xbits
        cdef int block_yi = yi >> self.block_ybits
        # this is the flat index for the block
        cdef int block_index = block_yi * self.block_nx + block_xi
        if not self.lru_cache.exist(block_index):
            self._load_block(block_index)
        self.lru_cache.get(
            block_index)[
                ((yi & (self.block_ymod)) << self.block_xbits) +
                (xi & (self.block_xmod))] = value
        if self.write_mode:
            dirty_itr = self.dirty_blocks.find(block_index)
            if dirty_itr == self.dirty_blocks.end():
                self.dirty_blocks.insert(block_index)

    cdef inline double get(self, int xi, int yi):
        """Return the value of the pixel at `xi,yi`."""
        if xi < 0 or xi >= self.raster_x_size:
            LOGGER.error("x out of bounds %s" % xi)
        if yi < 0 or yi >= self.raster_y_size:
            LOGGER.error("y out of bounds %s" % yi)
        cdef int block_xi = xi >> self.block_xbits
        cdef int block_yi = yi >> self.block_ybits
        # this is the flat index for the block
        cdef int block_index = block_yi * self.block_nx + block_xi
        if not self.lru_cache.exist(block_index):
            self._load_block(block_index)
        return self.lru_cache.get(
            block_index)[
                ((yi & (self.block_ymod)) << self.block_xbits) +
                (xi & (self.block_xmod))]

    cdef void _load_block(self, int block_index) except *:
        cdef int block_xi = block_index % self.block_nx
        cdef int block_yi = block_index // self.block_nx

        # we need the offsets to subtract from global indexes for cached array
        cdef int xoff = block_xi << self.block_xbits
        cdef int yoff = block_yi << self.block_ybits

        cdef int xi_copy, yi_copy
        cdef numpy.ndarray[double, ndim=2] block_array
        cdef double *double_buffer
        cdef clist[BlockBufferPair] removed_value_list

        # determine the block aligned xoffset for read as array

        # initially the win size is the same as the block size unless
        # we're at the edge of a raster
        cdef int win_xsize = self.block_xsize
        cdef int win_ysize = self.block_ysize

        # load a new block
        if xoff+win_xsize > self.raster_x_size:
            win_xsize = win_xsize - (xoff+win_xsize - self.raster_x_size)
        if yoff+win_ysize > self.raster_y_size:
            win_ysize = win_ysize - (yoff+win_ysize - self.raster_y_size)

        raster = gdal.OpenEx(self.raster_path, gdal.OF_RASTER)
        raster_band = raster.GetRasterBand(self.band_id)
        block_array = raster_band.ReadAsArray(
            xoff=xoff, yoff=yoff, win_xsize=win_xsize,
            win_ysize=win_ysize).astype(numpy.float64)
        raster_band = None
        raster = None
        double_buffer = <double*>PyMem_Malloc(
            (sizeof(double) << self.block_xbits) * win_ysize)
        for xi_copy in range(win_xsize):
            for yi_copy in range(win_ysize):
                double_buffer[(yi_copy << self.block_xbits)+xi_copy] = (
                    block_array[yi_copy, xi_copy])
        self.lru_cache.put(
            <int>block_index, <double*>double_buffer, removed_value_list)

        if self.write_mode:
            n_attempts = 5
            while True:
                raster = gdal.OpenEx(
                    self.raster_path, gdal.GA_Update | gdal.OF_RASTER)
                if raster is None:
                    if n_attempts == 0:
                        raise RuntimeError(
                            f'could not open {self.raster_path} for writing')
                    LOGGER.warning(
                        f'opening {self.raster_path} resulted in null, '
                        f'trying {n_attempts} more times.')
                    n_attempts -= 1
                    time.sleep(0.5)
                raster_band = raster.GetRasterBand(self.band_id)
                break

        block_array = numpy.empty(
            (self.block_ysize, self.block_xsize), dtype=numpy.double)
        while not removed_value_list.empty():
            # write the changed value back if desired
            double_buffer = removed_value_list.front().second

            if self.write_mode:
                block_index = removed_value_list.front().first

                # write back the block if it's dirty
                dirty_itr = self.dirty_blocks.find(block_index)
                if dirty_itr != self.dirty_blocks.end():
                    self.dirty_blocks.erase(dirty_itr)

                    block_xi = block_index % self.block_nx
                    block_yi = block_index // self.block_nx

                    xoff = block_xi << self.block_xbits
                    yoff = block_yi << self.block_ybits

                    win_xsize = self.block_xsize
                    win_ysize = self.block_ysize

                    if xoff+win_xsize > self.raster_x_size:
                        win_xsize = win_xsize - (
                            xoff+win_xsize - self.raster_x_size)
                    if yoff+win_ysize > self.raster_y_size:
                        win_ysize = win_ysize - (
                            yoff+win_ysize - self.raster_y_size)

                    for xi_copy in range(win_xsize):
                        for yi_copy in range(win_ysize):
                            block_array[yi_copy, xi_copy] = double_buffer[
                                (yi_copy << self.block_xbits) + xi_copy]
                    raster_band.WriteArray(
                        block_array[0:win_ysize, 0:win_xsize],
                        xoff=xoff, yoff=yoff)
            PyMem_Free(double_buffer)
            removed_value_list.pop_front()

        if self.write_mode:
            raster_band = None
            raster = None

    cdef void flush(self) except *:
        cdef clist[BlockBufferPair] removed_value_list
        cdef double *double_buffer
        cdef cset[int].iterator dirty_itr
        cdef int block_index, block_xi, block_yi
        cdef int xoff, yoff, win_xsize, win_ysize

        self.lru_cache.clean(removed_value_list, self.lru_cache.size())

        raster_band = None
        if self.write_mode:
            max_retries = 5
            while max_retries > 0:
                raster = gdal.OpenEx(
                    self.raster_path, gdal.GA_Update | gdal.OF_RASTER)
                if raster is None:
                    max_retries -= 1
                    LOGGER.error(
                        f'unable to open {self.raster_path}, retrying...')
                    time.sleep(0.2)
                    continue
                break
            if max_retries == 0:
                raise ValueError(
                    f'unable to open {self.raster_path} in '
                    'ManagedRaster.flush')
            raster_band = raster.GetRasterBand(self.band_id)

        block_array = numpy.empty(
            (self.block_ysize, self.block_xsize), dtype=numpy.double)
        while not removed_value_list.empty():
            # write the changed value back if desired
            double_buffer = removed_value_list.front().second

            if self.write_mode:
                block_index = removed_value_list.front().first

                # write back the block if it's dirty
                dirty_itr = self.dirty_blocks.find(block_index)
                if dirty_itr != self.dirty_blocks.end():
                    self.dirty_blocks.erase(dirty_itr)

                    block_xi = block_index % self.block_nx
                    block_yi = block_index // self.block_nx

                    xoff = block_xi << self.block_xbits
                    yoff = block_yi << self.block_ybits

                    win_xsize = self.block_xsize
                    win_ysize = self.block_ysize

                    if xoff+win_xsize > self.raster_x_size:
                        win_xsize = win_xsize - (
                            xoff+win_xsize - self.raster_x_size)
                    if yoff+win_ysize > self.raster_y_size:
                        win_ysize = win_ysize - (
                            yoff+win_ysize - self.raster_y_size)

                    for xi_copy in range(win_xsize):
                        for yi_copy in range(win_ysize):
                            block_array[yi_copy, xi_copy] = double_buffer[
                                (yi_copy << self.block_xbits) + xi_copy]
                    raster_band.WriteArray(
                        block_array[0:win_ysize, 0:win_xsize],
                        xoff=xoff, yoff=yoff)
            PyMem_Free(double_buffer)
            removed_value_list.pop_front()

        if self.write_mode:
            raster_band = None
            raster = None


def _scrub_invalid_values(base_array, nodata, new_nodata):
    result = numpy.copy(base_array)
    invalid_mask = (
        ~numpy.isfinite(base_array) |
        numpy.isclose(result, nodata))
    result[invalid_mask] = new_nodata
    return result


def build_flood_height():
    """floo dnight."""


def floodplane_extraction(
        dem_path, stream_gauge_vector_path, target_floodplane_raster_path,
        min_flow_accum_threshold=2000):
    """Entry point."""
    dem_info = pygeoprocessing.get_raster_info(dem_path)
    dem_type = dem_info['numpy_type']
    working_dir = os.path.join(
        os.path.dirname(target_floodplane_raster_path),
        f'''workspace_{os.path.basename(os.path.splitext(
            target_floodplane_raster_path)[0])}''')
    nodata = dem_info['nodata'][0]
    new_nodata = float(numpy.finfo(dem_type).min)

    scrubbed_dem_path = os.path.join(working_dir, 'scrubbed_dem.tif')
    task_graph = taskgraph.TaskGraph(working_dir, -1)

    scrub_dem_task = task_graph.add_task(
        func=pygeoprocessing.raster_calculator,
        args=(
            [(dem_path, 1), (nodata, 'raw'), (new_nodata, 'raw')],
            _scrub_invalid_values, scrubbed_dem_path,
            dem_info['datatype'], new_nodata),
        target_path_list=[scrubbed_dem_path],
        task_name='scrub dem')

    LOGGER.info('fill pits')
    filled_pits_path = os.path.join(working_dir, 'filled_pits_dem.tif')
    fill_pits_task = task_graph.add_task(
        func=pygeoprocessing.routing.fill_pits,
        args=((scrubbed_dem_path, 1), filled_pits_path),
        target_path_list=[filled_pits_path],
        dependent_task_list=[scrub_dem_task],
        task_name='fill pits')

    LOGGER.info('flow dir d8')
    flow_dir_d8_path = os.path.join(working_dir, 'flow_dir_d8.tif')
    flow_dir_task = task_graph.add_task(
        func=pygeoprocessing.routing.flow_dir_d8,
        args=((filled_pits_path, 1), flow_dir_d8_path),
        kwargs={'working_dir': working_dir},
        target_path_list=[flow_dir_d8_path],
        dependent_task_list=[fill_pits_task],
        task_name='flow dir d8')

    LOGGER.info('flow accum d8')
    flow_accum_d8_path = os.path.join(working_dir, 'flow_accum_d8.tif')
    flow_accum_task = task_graph.add_task(
        func=pygeoprocessing.routing.flow_accumulation_d8,
        args=((flow_dir_d8_path, 1), flow_accum_d8_path),
        target_path_list=[flow_accum_d8_path],
        dependent_task_list=[flow_dir_task],
        task_name='flow accum d8')

    stream_vector_path = os.path.join(
        working_dir, f'stream_segments_{min_flow_accum_threshold}.gpkg')
    extract_stream_task = task_graph.add_task(
        func=pygeoprocessing.routing.extract_strahler_streams_d8,
        args=(
            (flow_dir_d8_path, 1), (flow_accum_d8_path, 1),
            (filled_pits_path, 1), stream_vector_path),
        kwargs={
            'min_flow_accum_threshold': min_flow_accum_threshold,
            'river_order': 7},
        target_path_list=[stream_vector_path],
        dependent_task_list=[flow_accum_task],
        task_name='stream extraction')

    target_watershed_boundary_vector_path = os.path.join(
        working_dir, 'watershed_boundary.gpkg')
    calculate_watershed_boundary_task = task_graph.add_task(
        func=pygeoprocessing.routing.calculate_subwatershed_boundary,
        args=(
            (flow_dir_d8_path, 1), stream_vector_path,
            target_watershed_boundary_vector_path),
        target_path_list=[target_watershed_boundary_vector_path],
        transient_run=True,
        dependent_task_list=[extract_stream_task],
        task_name='watershed boundary')

