# Verwende spezifische Version für Reproduzierbarkeit
FROM node:22.11-slim AS base

LABEL maintainer="Marko Kajzer <markokajzer91@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/markokajzer/discord-soundbot"
LABEL org.opencontainers.image.description="Discord Soundbot with Node.js 22"

RUN mkdir /app && chown -R node:node /app
WORKDIR /app

# Installiere tini in einem Layer
RUN apt-get -qq update && \
    apt-get -qq -y install --no-install-recommends \
    wget \
    ca-certificates && \
    wget -qO /tini https://github.com/krallin/tini/releases/download/v0.19.0/tini-$(dpkg --print-architecture) && \
    chmod +x /tini && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

####################################################################################################

FROM base AS builder

# Installiere nur notwendige Build-Dependencies
RUN apt-get -qq update && \
    apt-get -qq -y install --no-install-recommends \
    git \
    g++ \
    make \
    python3 \
    tar \
    xz-utils && \
    rm -rf /var/lib/apt/lists/*

# FFmpeg statisch installieren
RUN wget -qO /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-$(dpkg --print-architecture)-static.tar.xz && \
    mkdir -p /tmp/ffmpeg && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1 && \
    cp /tmp/ffmpeg/ffmpeg /tmp/ffmpeg/ffprobe /usr/local/bin/ && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    rm -rf /tmp/ffmpeg*

USER node

# Kopiere nur package files für besseres Caching
COPY --chown=node:node package*.json ./

# Installiere ALLE Dependencies inkl. devDependencies (TypeScript!)
# Wichtig: NODE_ENV darf NICHT production sein hier
RUN npm ci && \
    npm cache clean --force

# Kopiere Quellcode (inkl. tsconfig.json und src/)
COPY --chown=node:node . .

# TypeScript Build ausführen
RUN npm run build

# Jetzt Production-Dependencies neu installieren (ohne devDependencies)
# Dies entfernt TypeScript etc. für kleineres finales Image
RUN npm ci --only=production && \
    npm cache clean --force

####################################################################################################

FROM base AS production

# Setze NODE_ENV erst hier, damit es den Build nicht beeinflusst
ENV NODE_ENV=production \
    NPM_CONFIG_LOGLEVEL=warn

# Nur Runtime-Dependencies
RUN apt-get -qq update && \
    apt-get -qq -y install --no-install-recommends ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# FFmpeg von builder
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe

USER node

# Kopiere nur die gebauten Dateien und Production-Dependencies
COPY --from=builder --chown=node:node /app/dist /app/dist
COPY --from=builder --chown=node:node /app/node_modules /app/node_modules
COPY --from=builder --chown=node:node /app/package*.json /app/

# Kopiere auch config files falls vorhanden
COPY --from=builder --chown=node:node /app/config /app/config

VOLUME ["/app/sounds", "/app/config"]

ENTRYPOINT ["/tini", "--"]

# Korrekter Einstiegspunkt für TypeScript-Build
CMD ["node", "-r", "module-alias/register", "dist/bin/soundbot.js"]