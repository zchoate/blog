ARG NGINX_IMG=nginx:1.21

FROM klakegg/hugo:ext-ubuntu AS hugo

ADD . /src
RUN hugo

FROM ${NGINX_IMG}
COPY --from=hugo /src/public /usr/share/nginx/html