# MIT License
#
# (C) Copyright [2020-2021] Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

# Dockerfile for building HMS TRS Worker.

FROM arti.dev.cray.com/baseos-docker-master-local/golang:1.14-alpine3.12 AS build-base

RUN set -ex \
    && apk update \
    && apk add build-base

FROM build-base AS base

# Copy all the necessary files to the image.
COPY cmd $GOPATH/src/github.com/Cray-HPE/hms-trs-worker/cmd
COPY vendor $GOPATH/src/github.com/Cray-HPE/hms-trs-worker/vendor

### Build Stage ###

FROM base AS builder

# Now build
RUN set -ex \
    && go build -v -i -o worker github.com/Cray-HPE/hms-trs-worker/cmd/worker

### Final Stage ###

FROM arti.dev.cray.com/baseos-docker-master-local/alpine:3.12
LABEL maintainer="Hewlett Packard Enterprise"
STOPSIGNAL SIGTERM
EXPOSE 8376

# Setup environment variables.
ENV LOG_LEVEL="INFO"
# ENV BROKER_SPEC="cray-shared-kafka-kafka-bootstrap.services.svc.cluster.local:9092"
ENV BROKER_SPEC="kafka:9092"
ENV TOPICS_FILE="configs/active_topics.json"

RUN set -ex \
    && apk update \
    && apk add --no-cache curl

# Get worker from the builder stage.
COPY --from=builder /go/worker /usr/local/bin
COPY configs ${CONFIGS_DIR_PREFIX}configs
COPY .version /

# Set up the command to start the service, the run the init script.
CMD worker
