FROM nginx:1.27-alpine

COPY app/web/index.html app/web/app.js app/web/styles.css /usr/share/nginx/html/
COPY app/web/nginx.conf.template /etc/nginx/templates/default.conf.template

ENV API_UPSTREAM=api:8080 \
    NGINX_ENVSUBST_FILTER=^API_UPSTREAM$
EXPOSE 8080
