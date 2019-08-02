# --- Build image
FROM ruby:2.5.5-alpine3.10 as builder

# bundle install deps
RUN apk add --update ca-certificates git build-base openssl-dev
RUN gem install bundler -v '>= 2'

# rclone
RUN cd /tmp \
  && wget https://github.com/rclone/rclone/releases/download/v1.48.0/rclone-v1.48.0-linux-amd64.zip \
  && unzip rclone-*.zip \
  && mv rclone-*/rclone /

# influxd
RUN apk add influxdb

# bundle install
COPY . /influxbu
RUN cd /influxbu && bundle

# --- Runtime image
FROM ruby:2.5.5-alpine3.10

RUN wget -O /usr/bin/dumb-init https://github.com/Yelp/dumb-init/releases/download/v1.2.2/dumb-init_1.2.2_amd64 \
  && chmod +x /usr/bin/dumb-init
RUN wget -O /usr/bin/confd https://github.com/kelseyhightower/confd/releases/download/v0.16.0/confd-0.16.0-linux-amd64 \
  && chmod +x /usr/bin/confd
COPY --from=builder /rclone/ /usr/bin/rclone
COPY --from=builder /influxbu /opt/influxbu
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /usr/sbin/influxd /usr/sbin

RUN apk --update upgrade && apk add --no-cache ca-certificates

RUN addgroup -g 1000 -S influxbu \
  && adduser -u 1000 -S influxbu -G influxbu \
  && chown -R influxbu: /opt/influxbu

USER influxbu

VOLUME /home/influxbu/.config/rclone/rclone.conf

WORKDIR /opt/influxbu
ENTRYPOINT ["bundle", "exec", "ruby", "-I.", "main.rb", "backup"]
CMD []
