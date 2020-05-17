ARG PROJ_INSTALL_PREFIX=/usr/local
ARG BASE_IMAGE=ubuntu:20.04

FROM $BASE_IMAGE as builder

# Derived from osgeo/proj by Howard Butler <howard@hobu.co>
LABEL maintainer="Even Rouault <even.rouault@spatialys.com>"

# Setup build env for PROJ
RUN apt-get update -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing --no-install-recommends \
            software-properties-common build-essential ca-certificates \
            git make cmake wget unzip libtool automake \
            zlib1g-dev libsqlite3-dev pkg-config sqlite3 libcurl4-gnutls-dev \
            libtiff5-dev

# Setup build env for GDAL
RUN apt-get update -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing --no-install-recommends \
       libcharls-dev libopenjp2-7-dev libcairo2-dev \
       python3-dev python3-numpy \
       libpng-dev libjpeg-dev libgif-dev liblzma-dev libgeos-dev \
       curl libxml2-dev libexpat-dev libxerces-c-dev \
       libnetcdf-dev libpoppler-dev libpoppler-private-dev \
       libspatialite-dev swig libhdf4-alt-dev libhdf5-serial-dev \
       libfreexl-dev unixodbc-dev libwebp-dev libepsilon-dev \
       liblcms2-2 libpcre3-dev libcrypto++-dev libdap-dev libfyba-dev \
       libkml-dev libmysqlclient-dev libogdi-dev \
       libcfitsio-dev openjdk-8-jdk libzstd-dev \
       libpq-dev libssl-dev libboost-dev \
       autoconf automake bash-completion libarmadillo-dev \
       libopenexr-dev

# Build likbkea
ARG KEA_VERSION=1.4.13
RUN wget -q https://github.com/ubarsc/kealib/archive/kealib-${KEA_VERSION}.zip \
    && unzip -q kealib-${KEA_VERSION}.zip \
    && rm -f kealib-${KEA_VERSION}.zip \
    && cd kealib-kealib-${KEA_VERSION} \
    && cmake . -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr -DHDF5_INCLUDE_DIR=/usr/include/hdf5/serial \
        -DHDF5_LIB_PATH=/usr/lib/x86_64-linux-gnu/hdf5/serial -DLIBKEA_WITH_GDAL=OFF \
    && make -j$(nproc) \
    && make install DESTDIR="/build_thirdparty" \
    && make install \
    && cd .. \
    && rm -rf kealib-kealib-${KEA_VERSION} \
    && for i in /build_thirdparty/usr/lib/*; do strip -s $i 2>/dev/null || /bin/true; done \
    && for i in /build_thirdparty/usr/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build mongo-c-driver
ARG MONGO_C_DRIVER_VERSION=1.16.2
RUN mkdir mongo-c-driver \
    && wget -q https://github.com/mongodb/mongo-c-driver/releases/download/${MONGO_C_DRIVER_VERSION}/mongo-c-driver-${MONGO_C_DRIVER_VERSION}.tar.gz -O - \
        | tar xz -C mongo-c-driver --strip-components=1 \
    && cd mongo-c-driver \
    && mkdir build_cmake \
    && cd build_cmake \
    && cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DENABLE_TESTS=NO -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc) \
    && make install DESTDIR="/build_thirdparty" \
    && make install \
    && cd ../.. \
    && rm -rf mongo-c-driver \
    && rm /build_thirdparty/usr/lib/x86_64-linux-gnu/*.a \
    && for i in /build_thirdparty/usr/lib/x86_64-linux-gnu/*; do strip -s $i 2>/dev/null || /bin/true; done \
    && for i in /build_thirdparty/usr/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build mongocxx
ARG MONGOCXX_VERSION=3.5.0
RUN mkdir mongocxx \
    && wget -q https://github.com/mongodb/mongo-cxx-driver/archive/r${MONGOCXX_VERSION}.tar.gz -O - \
        | tar xz -C mongocxx --strip-components=1 \
    && cd mongocxx \
    && mkdir build_cmake \
    && cd build_cmake \
    && cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DBSONCXX_POLY_USE_BOOST=ON -DMONGOCXX_ENABLE_SLOW_TESTS=NO -DCMAKE_BUILD_TYPE=Release -DBUILD_VERSION=${MONGOCXX_VERSION} \
    && make -j$(nproc) \
    && make install DESTDIR="/build_thirdparty" \
    && make install \
    && cd ../.. \
    && rm -rf mongocxx \
    && for i in /build_thirdparty/usr/lib/x86_64-linux-gnu/*; do strip -s $i 2>/dev/null || /bin/true; done \
    && for i in /build_thirdparty/usr/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build tiledb
ARG TILEDB_VERSION=1.7.7
RUN mkdir tiledb \
    && wget -q https://github.com/TileDB-Inc/TileDB/archive/${TILEDB_VERSION}.tar.gz -O - \
        | tar xz -C tiledb --strip-components=1 \
    && cd tiledb \
    && mkdir build_cmake \
    && cd build_cmake \
    && ../bootstrap --prefix=/usr \
    && make -j$(nproc) \
    && make install-tiledb DESTDIR="/build_thirdparty" \
    && make install-tiledb \
    && cd ../.. \
    && rm -rf tiledb \
    && for i in /build_thirdparty/usr/lib/x86_64-linux-gnu/*; do strip -s $i 2>/dev/null || /bin/true; done \
    && for i in /build_thirdparty/usr/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build openjpeg
ARG OPENJPEG_VERSION=
RUN if test "${OPENJPEG_VERSION}" != ""; then ( \
    wget -q https://github.com/uclouvain/openjpeg/archive/v${OPENJPEG_VERSION}.tar.gz \
    && tar xzf v${OPENJPEG_VERSION}.tar.gz \
    && rm -f v${OPENJPEG_VERSION}.tar.gz \
    && cd openjpeg-${OPENJPEG_VERSION} \
    && cmake . -DBUILD_SHARED_LIBS=ON  -DBUILD_STATIC_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
    && make -j$(nproc) \
    && make install \
    && mkdir -p /build_thirdparty/usr/lib/x86_64-linux-gnu \
    && rm -f /usr/lib/x86_64-linux-gnu/libopenjp2.so* \
    && mv /usr/lib/libopenjp2.so* /usr/lib/x86_64-linux-gnu \
    && cp -P /usr/lib/x86_64-linux-gnu/libopenjp2.so* /build_thirdparty/usr/lib/x86_64-linux-gnu \
    && for i in /build_thirdparty/usr/lib/x86_64-linux-gnu/*; do strip -s $i 2>/dev/null || /bin/true; done \
    && cd .. \
    && rm -rf openjpeg-${OPENJPEG_VERSION} \
    ); fi

RUN apt-get update -y \
    && apt-get install -y --fix-missing --no-install-recommends rsync ccache
ARG RSYNC_REMOTE

# Build PROJ
ARG PROJ_VERSION=master
ARG PROJ_INSTALL_PREFIX
RUN mkdir proj \
    && wget -q https://github.com/OSGeo/PROJ/archive/${PROJ_VERSION}.tar.gz -O - \
        | tar xz -C proj --strip-components=1 \
    && cd proj \
    && ./autogen.sh \
    && if test "${RSYNC_REMOTE}" != ""; then \
        echo "Downloading cache..."; \
        rsync -ra ${RSYNC_REMOTE}/proj/ $HOME/; \
        echo "Finished"; \
        export CC="ccache gcc"; \
        export CXX="ccache g++"; \
        export PROJ_DB_CACHE_DIR="$HOME/.ccache"; \
        ccache -M 100M; \
    fi \
    && CFLAGS='-DPROJ_RENAME_SYMBOLS -O2' CXXFLAGS='-DPROJ_RENAME_SYMBOLS -DPROJ_INTERNAL_CPP_NAMESPACE -O2' \
        ./configure --prefix=${PROJ_INSTALL_PREFIX} --disable-static \
    && make -j$(nproc) \
    && make install DESTDIR="/build" \
    && if test "${RSYNC_REMOTE}" != ""; then \
        ccache -s; \
        echo "Uploading cache..."; \
        rsync -ra --delete $HOME/.ccache ${RSYNC_REMOTE}/proj/; \
        echo "Finished"; \
        rm -rf $HOME/.ccache; \
        unset CC; \
        unset CXX; \
    fi \
    && cd .. \
    && rm -rf proj \
    && PROJ_SO=$(readlink /build${PROJ_INSTALL_PREFIX}/lib/libproj.so | sed "s/libproj\.so\.//") \
    && PROJ_SO_FIRST=$(echo $PROJ_SO | awk 'BEGIN {FS="."} {print $1}') \
    && mv /build${PROJ_INSTALL_PREFIX}/lib/libproj.so.${PROJ_SO} /build${PROJ_INSTALL_PREFIX}/lib/libinternalproj.so.${PROJ_SO} \
    && ln -s libinternalproj.so.${PROJ_SO} /build${PROJ_INSTALL_PREFIX}/lib/libinternalproj.so.${PROJ_SO_FIRST} \
    && ln -s libinternalproj.so.${PROJ_SO} /build${PROJ_INSTALL_PREFIX}/lib/libinternalproj.so \
    && rm /build${PROJ_INSTALL_PREFIX}/lib/libproj.*  \
    && ln -s libinternalproj.so.${PROJ_SO} /build${PROJ_INSTALL_PREFIX}/lib/libproj.so.${PROJ_SO_FIRST} \
    && strip -s /build${PROJ_INSTALL_PREFIX}/lib/libinternalproj.so.${PROJ_SO} \
    && for i in /build${PROJ_INSTALL_PREFIX}/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

ARG GDAL_VERSION=3.0.4
ARG GDAL_RELEASE_DATE
ARG GDAL_BUILD_IS_RELEASE

# Build GDAL
RUN if test "${GDAL_VERSION}" = "master"; then \
        export GDAL_VERSION=$(curl -Ls https://api.github.com/repos/OSGeo/gdal/commits/HEAD -H "Accept: application/vnd.github.VERSION.sha"); \
        export GDAL_RELEASE_DATE=$(date "+%Y%m%d"); \
    fi \
    && if test "x${GDAL_BUILD_IS_RELEASE}" = "x"; then \
        export GDAL_SHA1SUM=${GDAL_VERSION}; \
    fi \
    && mkdir gdal \
    && wget -q https://github.com/OSGeo/gdal/releases/download/v${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz -O - \
        | tar xz -C gdal --strip-components=1 \
    && cd gdal \
    && if test "${RSYNC_REMOTE}" != ""; then \
        echo "Downloading cache..."; \
        rsync -ra ${RSYNC_REMOTE}/gdal/ $HOME/; \
        echo "Finished"; \
        # Little trick to avoid issues with Python bindings
        printf "#!/bin/sh\nccache gcc \$*" > ccache_gcc.sh; \
        chmod +x ccache_gcc.sh; \
        printf "#!/bin/sh\nccache g++ \$*" > ccache_g++.sh; \
        chmod +x ccache_g++.sh; \
        export CC=$PWD/ccache_gcc.sh; \
        export CXX=$PWD/ccache_g++.sh; \
        ccache -M 1G; \
    fi \
    && ./configure --prefix=/usr --without-libtool \
    --with-hide-internal-symbols \
    --with-jpeg12 \
    --with-python --with-poppler --with-spatialite --with-mysql --with-liblzma \
    --with-webp --with-epsilon --with-proj=/build/usr/local --with-poppler \
    --with-hdf5 --with-dods-root=/usr --with-sosi --with-mysql \
    --with-libtiff=internal --with-rename-internal-libtiff-symbols \
    --with-geotiff=internal --with-rename-internal-libgeotiff-symbols \
    --with-kea=/usr/bin/kea-config --with-mongocxxv3 --with-tiledb \
    --with-crypto \
    && make -j$(nproc) \
    && make install DESTDIR="/build" \
    && if test "${RSYNC_REMOTE}" != ""; then \
        ccache -s; \
        echo "Uploading cache..."; \
        rsync -ra --delete $HOME/.ccache ${RSYNC_REMOTE}/gdal/; \
        echo "Finished"; \
        rm -rf $HOME/.ccache; \
        unset CC; \
        unset CXX; \
    fi \
    && cd ../.. \
    && rm -rf gdal \
    && mkdir -p /build_gdal_python/usr/lib \
    && mkdir -p /build_gdal_python/usr/bin \
    && mkdir -p /build_gdal_version_changing/usr/include \
    && mv /build/usr/lib/python3            /build_gdal_python/usr/lib \
    && mv /build/usr/lib                    /build_gdal_version_changing/usr \
    && mv /build/usr/include/gdal_version.h /build_gdal_version_changing/usr/include \
    && mv /build/usr/bin/*.py               /build_gdal_python/usr/bin \
    && mv /build/usr/bin                    /build_gdal_version_changing/usr \
    && for i in /build_gdal_version_changing/usr/lib/*; do strip -s $i 2>/dev/null || /bin/true; done \
    && for i in /build_gdal_python/usr/lib/python3/dist-packages/osgeo/*.so; do strip -s $i 2>/dev/null || /bin/true; done \
    && for i in /build_gdal_version_changing/usr/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build final image
FROM $BASE_IMAGE as runner

RUN date

# PROJ dependencies
RUN apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        libsqlite3-0 libtiff5 libcurl4 \
        wget curl unzip ca-certificates

# GDAL dependencies
RUN apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        libcharls2 libopenjp2-7 libcairo2 python3-numpy \
        libpng16-16 libjpeg-turbo8 libgif7 liblzma5 libgeos-3.8.0 libgeos-c1v5 \
        libxml2 libexpat1 \
        libxerces-c3.2 libnetcdf-c++4 netcdf-bin libpoppler97 libspatialite7 gpsbabel \
        libhdf4-0-alt libhdf5-103 libhdf5-cpp-103 poppler-utils libfreexl1 unixodbc libwebp6 \
        libepsilon1 liblcms2-2 libpcre3 libcrypto++6 libdap25 libdapclient6v5 libfyba0 \
        libkmlbase1 libkmlconvenience1 libkmldom1 libkmlengine1 libkmlregionator1 libkmlxsd1 \
        libmysqlclient21 libogdi4.1 libcfitsio8 openjdk-8-jre \
        libzstd1 bash bash-completion libpq5 libssl1.1 \
        libarmadillo9 libpython3.8 libopenexr24

# Order layers starting with less frequently varying ones
ARG PROJ_DATUMGRID_LATEST_LAST_MODIFIED
ARG PROJ_INSTALL_PREFIX
RUN \
    mkdir -p ${PROJ_INSTALL_PREFIX}/share/proj; \
    wget --no-verbose --mirror https://cdn.proj.org/; \
    rm -f cdn.proj.org/*.js; \
    rm -f cdn.proj.org/*.css; \
    mv cdn.proj.org/* ${PROJ_INSTALL_PREFIX}/share/proj/; \
    rmdir cdn.proj.org

RUN apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y python-is-python3

COPY --from=builder  /build_thirdparty/usr/ /usr/

COPY --from=builder  /build${PROJ_INSTALL_PREFIX}/share/proj/ ${PROJ_INSTALL_PREFIX}/share/proj/
COPY --from=builder  /build${PROJ_INSTALL_PREFIX}/include/ ${PROJ_INSTALL_PREFIX}/include/
COPY --from=builder  /build${PROJ_INSTALL_PREFIX}/bin/ ${PROJ_INSTALL_PREFIX}/bin/
COPY --from=builder  /build${PROJ_INSTALL_PREFIX}/lib/ ${PROJ_INSTALL_PREFIX}/lib/

COPY --from=builder  /build/usr/share/gdal/ /usr/share/gdal/
COPY --from=builder  /build/usr/include/ /usr/include/
COPY --from=builder  /build_gdal_python/usr/ /usr/
COPY --from=builder  /build_gdal_version_changing/usr/ /usr/

RUN ldconfig
RUN apt-get install -y openjdk-11-jdk-headless
RUN apt-get install -y \
    emacs \
    openjdk-11-jdk

RUN apt update && apt upgrade -y
RUN apt install libspatialindex-dev -y

RUN apt install python3-pip -y
RUN pip3 install \
    Cython \
    flask \
    matplotlib \
    requests \
    retrying \
    rtree \
    scipy \
    shapely

RUN apt install -y \
    openssl \
    curl
SHELL ["/bin/bash", "-c"]
WORKDIR /usr/local/gcloud-sdk
RUN wget https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-284.0.0-linux-x86_64.tar.gz && tar -xvzf google-cloud-sdk-284.0.0-linux-x86_64.tar.gz
RUN ./google-cloud-sdk/install.sh
RUN source /usr/local/gcloud-sdk/google-cloud-sdk/completion.bash.inc
RUN source /usr/local/gcloud-sdk/google-cloud-sdk/path.bash.inc
RUN echo "export PATH=$PATH:/usr/local/gcloud-sdk/google-cloud-sdk/bin" >> /root/.bashrc

RUN apt install git -y
RUN pip3 install git+https://github.com/natcap/pygeoprocessing.git@release/2.0
RUN pip3 install ecoshard==0.4.0
RUN pip3 install pandas

COPY inspring /usr/local/inspring
WORKDIR /usr/local/inspring
RUN /usr/bin/python setup.py install

WORKDIR /usr/local/workspace
ENTRYPOINT ["/usr/bin/python"]
