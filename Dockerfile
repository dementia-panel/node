FROM golang:1.25.11-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev make git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN version=v3.1.20260812 \
    && git clone --depth 1 --branch "$version" https://github.com/amnezia-vpn/amneziawg-go.git /src/awg-go \
    && git clone --depth 1 --branch "$version" https://github.com/amnezia-vpn/amneziawg-tools.git /src/tools \
    && make -C /src/awg-go \
    && make -C /src/tools/src

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates iproute2 iptables python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/awg-go/amneziawg-go /usr/local/bin/amneziawg-go
COPY --from=build /src/tools/src/wg /usr/local/bin/awg
COPY entrypoint.sh sync.py /opt/dementia/
ENTRYPOINT ["/bin/bash", "/opt/dementia/entrypoint.sh"]
