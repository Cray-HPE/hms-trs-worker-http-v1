# Copyright 2020 Hewlett Packard Enterprise Development LP

# Dockerfile for building HMS TRS Worker.

FROM dtr.dev.cray.com/baseos/golang:1.14-alpine3.12 AS build-base

RUN set -ex \
    && apk update \
    && apk add build-base

FROM build-base AS base

# Copy all the necessary files to the image.
COPY cmd $GOPATH/src/stash.us.cray.com/HMS/hms-trs-worker/cmd
COPY vendor $GOPATH/src/stash.us.cray.com/HMS/hms-trs-worker/vendor

### Build Stage ###

FROM base AS builder

# Now build
RUN set -ex \
    && go build -v -i -o worker stash.us.cray.com/HMS/hms-trs-worker/cmd/worker

### Final Stage ###

FROM dtr.dev.cray.com/baseos/alpine:3.12
LABEL maintainer="Cray, Inc."
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