# Apache Atlas 2.4.0, built from the official source release of the Apache Software
# Foundation, for the checks of the context from a data catalog (tests/context.sh).
# The release is checked against its SHA-512, the one downloads.apache.org publishes next to
# it. Atlas publishes no binary: the first stage builds the server's distribution with Maven,
# tests skipped. The image then holds the two services Atlas stores into, at the versions the
# release itself names for an embedded setup (hbase.version and solr.version of its pom.xml),
# from the ASF archive, each checked against its published SHA-512:
#   - Apache HBase, in standalone mode, for the graph and its audit;
#   - Apache Solr, in cloud mode on HBase's ZooKeeper, for the indexes.
# Atlas runs its own embedded Kafka for its notifications. Everything runs as uid 1000.
# For a laptop demo only: no TLS, file-based users, state lost with the container.

# Base images pinned by the digest of their multi-platform index.
FROM maven:3.9.9-eclipse-temurin-8@sha256:e20e4fc05fb5480c884a1f750c362ed0e91aca15cec5736e12796713710ec9b3 AS build
ARG ATLAS_VERSION=2.4.0
ARG ATLAS_SHA512=870bc43d17e7744fb74a71bd3bf0ae4d5243ba741ef26a33c9beb365c46ed95ac366e0f7738368ef0d8cb0f9b5c7a7de3eb2c2666f4c4d0a91c0c0ee58b67c81
WORKDIR /build
# The web dashboards build node-sass from its sources, with Python (its node-gyp imports
# distutils, which setuptools brings back on Python 3.12) and a C++ compiler.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-setuptools make g++ \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 5 --retry-all-errors -o atlas.tar.gz \
      "https://archive.apache.org/dist/atlas/${ATLAS_VERSION}/apache-atlas-${ATLAS_VERSION}-sources.tar.gz" \
 && echo "${ATLAS_SHA512}  atlas.tar.gz" | sha512sum -c - \
 && tar xzf atlas.tar.gz --strip-components 1 \
 && rm atlas.tar.gz
# The server's distribution and what it is built from; the release's tests are not run. The
# Maven repository is a build cache, never part of an image.
RUN --mount=type=cache,target=/root/.m2 \
    MAVEN_OPTS="-Xmx2g" mvn -B -ntp -DskipTests -Drat.skip=true -Pdist -pl distro -am package \
 && mkdir /dist \
 && tar xzf "distro/target/apache-atlas-${ATLAS_VERSION}-server.tar.gz" -C /dist \
 && mv "/dist/apache-atlas-${ATLAS_VERSION}" /dist/atlas

FROM eclipse-temurin:8u462-b08-jdk-jammy@sha256:5609f981ccb84b19af42dfc0e68b7adccc07d2854e7c820ec89227f3dc04d4ce
ARG HBASE_VERSION=2.5.0
ARG HBASE_SHA512=1e0ebf9a457a8ed59a0e1ea06eaa6019f63575c317588175f18ee2506cf0e527516952cb026db84d4af890be35f74c29f8e87c41e0dcf99393c09bd48668e16f
ARG SOLR_VERSION=8.11.3
ARG SOLR_SHA512=10f09b163bd9c31b2a8fdf889cf624114648e76881d69a4c096d473272c47b3cbe37ec9f9bd1980fd90967352c4052477065e165127eccb2c49a60c8d9860afc
ENV ATLAS_HOME=/opt/atlas HBASE_HOME=/opt/hbase SOLR_DIR=/opt/solr
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python-is-python3 procps lsof netcat-openbsd \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 1000 atlas && useradd -u 1000 -g atlas -d /home/atlas -m atlas \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors -o hbase.tar.gz \
      "https://archive.apache.org/dist/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz" \
 && curl -fsSL --retry 5 --retry-all-errors -o solr.tgz \
      "https://archive.apache.org/dist/lucene/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz" \
 && printf '%s  hbase.tar.gz\n%s  solr.tgz\n' "${HBASE_SHA512}" "${SOLR_SHA512}" | sha512sum -c - \
 && tar xzf hbase.tar.gz -C /opt && mv "/opt/hbase-${HBASE_VERSION}" "${HBASE_HOME}" \
 && tar xzf solr.tgz -C /opt && mv "/opt/solr-${SOLR_VERSION}" "${SOLR_DIR}" \
 && rm -f /tmp/hbase.tar.gz /tmp/solr.tgz \
 && mkdir -p /data && chown -R atlas:atlas "${HBASE_HOME}" "${SOLR_DIR}" /data
COPY --from=build --chown=atlas:atlas /dist/atlas ${ATLAS_HOME}
COPY start.sh /usr/local/bin/start-atlas.sh
USER 1000
EXPOSE 21000
ENTRYPOINT ["/bin/bash", "/usr/local/bin/start-atlas.sh"]
