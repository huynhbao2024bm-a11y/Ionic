FROM postgres@sha256:eee6c6e1b0894fa4fe0075eb054af9fd1cf39a35321c2d4110626cfe506411fb
# Same PostgreSQL 17.11 Alpine base as the existing development cluster.
# Pin source and checksum; build portable CPU code without an LLVM dependency.
ADD --checksum=sha256:cac0b10c360f05b2d521200105ba3697e773d4cd3731f5a915a7e37ebe0bea85 https://codeload.github.com/pgvector/pgvector/tar.gz/refs/tags/v0.8.7 /tmp/pgvector.tar.gz
RUN apk add --no-cache --virtual .vector-build build-base \
    && tar -xzf /tmp/pgvector.tar.gz -C /tmp \
    && cd /tmp/pgvector-0.8.7 \
    && make with_llvm=no OPTFLAGS="" \
    && make with_llvm=no install \
    && mkdir -p /usr/local/share/doc/pgvector \
    && cp LICENSE /usr/local/share/doc/pgvector/LICENSE \
    && rm -rf /tmp/pgvector-0.8.7 /tmp/pgvector.tar.gz \
    && apk del .vector-build
