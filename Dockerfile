ARG CADDY_VERSION

FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/WeidiDeng/caddy-cloudflare-ip \
    --with github.com/fvbommel/caddy-combine-ip-ranges \
    --with github.com/caddy-dns/route53 \
    --with github.com/porech/caddy-maxmind-geolocation \
    --with github.com/caddyserver/ntlm-transport

FROM caddy:${CADDY_VERSION}

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

RUN /usr/bin/caddy version
RUN /usr/bin/caddy list-modules --skip-standard --versions

