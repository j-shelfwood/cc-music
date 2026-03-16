# Stage 1: Build Astro frontend
FROM node:22-alpine AS frontend-builder
WORKDIR /web
COPY web/package.json web/package-lock.json* ./
RUN npm install
COPY web/ ./
RUN npm run build

# Stage 2: Runtime — Nginx + PHP-FPM + ffmpeg + yt-dlp
FROM php:8.2-fpm

RUN apt-get update && apt-get install -y \
    nginx \
    ffmpeg \
    python3 \
    python3-pip \
    curl \
    unzip \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod +x /usr/local/bin/yt-dlp

# Install deno
RUN curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path \
    && mv /root/.deno/bin/deno /usr/local/bin/deno

# Copy PHP API backend
COPY server/ /app/server/

# Copy built Astro frontend
COPY --from=frontend-builder /web/dist /app/web/

# Nginx config: static frontend on /, PHP API on /api/*
RUN cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 3001;
    server_name _;

    # Static Astro frontend
    root /app/web;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # PHP API backend
    location /api/ {
        root /app/server;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME /app/server/index.php;
        fastcgi_read_timeout 86400s;
        include fastcgi_params;
    }
}
EOF

# Startup script: run php-fpm + nginx
RUN printf '#!/bin/sh\nphp-fpm -D\nnginx -g "daemon off;"\n' > /start.sh && chmod +x /start.sh

EXPOSE 3001

CMD ["/start.sh"]
