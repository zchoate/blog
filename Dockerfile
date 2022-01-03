ARG NGINX_IMG=nginx:1.21

FROM klakegg/hugo:ext-ubuntu-onbuild AS hugo

ADD . /src
RUN hugo

FROM ${NGINX_IMG}
LABEL org.opencontainers.image.source=https://github.com/zchoate/blog
COPY --from=hugo /target /usr/share/nginx/html