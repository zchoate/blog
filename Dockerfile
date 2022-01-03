ARG NGINX_IMG=nginx:1.21

FROM klakegg/hugo:ext-ubuntu AS hugo

ADD . /src
RUN hugo

FROM ${NGINX_IMG}
LABEL org.opencontainers.image.source=https://github.com/zchoate/blog
COPY --from=hugo /src/public /usr/share/nginx/html