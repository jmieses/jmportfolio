FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y \
    build-essential git curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /site

# Copy gem manifests first so dependency layer is cached separately from source
COPY Gemfile Gemfile.lock* ./
RUN gem install bundler && bundle install

EXPOSE 4000 35729

# --force_polling ensures file changes are detected inside Docker volumes
# (native filesystem events don't reliably cross volume mounts on macOS/Windows)
CMD ["bundle", "exec", "jekyll", "serve", \
     "--host", "0.0.0.0", \
     "--livereload", \
     "--force_polling", \
     "--future"]
