FROM php:8.2-cli

# Install ffmpeg and Python3/pip for yt-dlp
RUN apt-get update && apt-get install -y \
    ffmpeg \
    python3 \
    python3-pip \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp (use official binary for reliability)
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod +x /usr/local/bin/yt-dlp

# Install deno (required for yt-dlp JS challenge solving / signature extraction)
RUN curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path \
    && mv /root/.deno/bin/deno /usr/local/bin/deno

WORKDIR /app

COPY server/ ./

EXPOSE 3001

# PHP built-in server — simple, zero config, fine for low traffic
CMD ["php", "-S", "0.0.0.0:3001", "index.php"]
