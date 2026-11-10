# Updater: keeps every Docker Compose app on the server up to date (see update-apps.sh)
FROM docker:27.5.1-cli
COPY --chmod=755 update-apps.sh /usr/local/bin/update-apps.sh
ENTRYPOINT ["/usr/local/bin/update-apps.sh"]
