# Laboratorio local de Sistemas Distribuidos - DNS / BIND 9
# Base proposta pelo roteiro da disciplina.
FROM alpine:3.20

RUN apk add --no-cache bind bind-tools && \
    mkdir -p /etc/bind /var/lib/bind/keys && \
    rndc-confgen -a -c /etc/bind/rndc.key -A hmac-sha256 && \
    chown -R named:named /var/lib/bind /etc/bind/rndc.key && \
    chmod 0640 /etc/bind/rndc.key

EXPOSE 53/udp 53/tcp
CMD ["named", "-g", "-u", "named", "-c", "/etc/bind/named.conf"]
