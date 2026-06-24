# Static React 18 SPA served by Nginx. React UMD is vendored into the image (no CDN, no Babel).
FROM nginx:1.27-alpine
RUN mkdir -p /usr/share/nginx/html/vendor && \
    wget -qO /usr/share/nginx/html/vendor/react.js     https://unpkg.com/react@18.3.1/umd/react.production.min.js && \
    wget -qO /usr/share/nginx/html/vendor/react-dom.js https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 3000
