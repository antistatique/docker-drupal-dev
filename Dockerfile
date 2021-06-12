FROM php:%%PHP_VERSION%%-apache

ENV APACHE_DOCUMENT_ROOT /var/www/web
ENV NODE_MAJOR_VERSION %%NODE_VERSION%%

ENV PATH="${PATH}:/var/www/node_modules/.bin:/var/www/vendor/bin:/var/www/bin"
ENV ARTIFACTS_DEST="/usr/bin/artifacts"

ENV COMPOSER_MEMORY_LIMIT=-1

# Install dependencies
RUN set -ex; \
  \
  mkdir -p /usr/share/man/man1 /usr/share/man/man7; \
  \
  if command -v a2enmod; then \
    a2enmod rewrite; \
    a2enmod headers; \
    a2enmod expires; \
  fi; \
  \
  savedAptMark="$(apt-mark showmanual)"; \
  \
  # install the installation dependencies we need
  apt-get update; \
  apt-get install -y --no-install-recommends \
    bc \
    gnupg \
    libicu-dev \
    libjpeg-dev \
    libpng-dev \
    libpq-dev \
    libwebp-dev \
    libzip-dev \
  ; \
  \
  # install the PHP extensions we need
  # GD configuration changed in PHP >7.4. See: https://github.com/docker-library/php/pull/910#issuecomment-559383597
  # test if $PHP_VERSION > 7.4 (source: https://stackoverflow.com/a/24067243)
  if [ "$(printf '%s\n' $PHP_VERSION 7.4 | sort -V | head -n 1)" != "$PHP_VERSION" ]; then \
    docker-php-ext-configure gd --with-jpeg --with-webp; \
  else \
    docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr --with-webp-dir=/usr; \
  fi; \
  \
  docker-php-ext-install -j "$(nproc)" \
    bcmath \
    gd \
    intl \
    opcache \
    pdo_mysql \
    pdo_pgsql \
    zip \
  ; \
  \
  # reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
  apt-mark auto '.*' > /dev/null; \
  apt-mark manual $savedAptMark; \
  ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
    | awk '/=>/ { print $3 }' \
    | sort -u \
    | xargs -r dpkg-query -S \
    | cut -d: -f1 \
    | sort -u \
    | xargs -rt apt-mark manual; \
  \
  # add node related repositories
  if [ "$NODE_MAJOR_VERSION" != "false" ]; then \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - ; \
    echo "deb http://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list; \
    \
    curl -sL https://deb.nodesource.com/setup_${NODE_MAJOR_VERSION}.x | bash - ; \
  fi; \
  \
  # update list of packages
  apt-get update; \
  \
  # install php running dependencies
  apt-get install -y --no-install-recommends \
    dnsutils \
    git \
    imagemagick \
    jq \
    libpng-dev \
    mariadb-client \
    netcat \
    sudo \
    unzip \
    vim \
    webp \
  ; \
  \
  # install node related dependencies
  if [ "$NODE_MAJOR_VERSION" != "false" ]; then \
    apt-get install -y --no-install-recommends \
      nodejs=$NODE_MAJOR_VERSION.* \
      python2.7 \
      yarn \
    ; \
    \
    npm config set --global python python2.7; \
  fi; \
  \
  # Install faketime
  # See https://github.com/wolfcw/libfaketime
  git clone https://github.com/wolfcw/libfaketime.git /usr/src/faketime; \
  ( \
    cd /usr/src/faketime; \
    make install; \
  ); \
  rm -rf /usr/src/faketime; \
  \
  # Install artifacts
  curl -fsSL https://raw.githubusercontent.com/travis-ci/artifacts/master/install | bash; \
  \
  # cleanup
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  rm -rf /var/lib/apt/lists/*

# setup apache
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Prepare symfony rewrite conf
RUN { \
    echo '<Directory /var/www/public>'; \
    echo '    RewriteEngine On'; \
    echo ''; \
    echo '    RewriteCond %{REQUEST_URI}::$1 ^(/.+)/(.*)::\2$'; \
    echo '    RewriteRule ^(.*) - [E=BASE:%1]'; \
    echo ''; \
    echo '    RewriteCond %{HTTP:Authorization} .'; \
    echo '    RewriteRule ^ - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]'; \
    echo ''; \
    echo '    RewriteCond %{ENV:REDIRECT_STATUS} ^$'; \
    echo '    RewriteRule ^index\.php(?:/(.*)|$) %{ENV:BASE}/$1 [R=301,L]'; \
    echo ''; \
    echo '    RewriteCond %{REQUEST_FILENAME} -f'; \
    echo '    RewriteRule ^ - [L]'; \
    echo '    RewriteRule ^ %{ENV:BASE}/index.php [L]'; \
    echo '</Directory>'; \
  } > /etc/apache2/conf-available/symfony-rewrite.conf

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
# revalidate_freq is set to 0 to avoid delay in development mode.
RUN { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=0'; \
    echo 'opcache.fast_shutdown=1'; \
    echo 'opcache.enable_cli=1'; \
  } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Set PHP settings for Docker
ENV PHP_MEMORY_LIMIT="256M"
RUN { \
    echo 'date.timezone="Europe/Zurich"'; \
    echo 'memory_limit=${PHP_MEMORY_LIMIT}'; \
  } > /usr/local/etc/php/conf.d/docker.ini

# install Composer.
RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer

# install custom scripts
COPY ./scripts/wait-for-it ./scripts/docker-as-* /usr/local/bin/
RUN chmod 755 /usr/local/bin/docker-as-* /usr/local/bin/wait-for-it

# set workdir and volume
RUN rm -rf /var/www/*
WORKDIR /var/www

# volumes
VOLUME /var/backups

CMD ["apache2-foreground"]
