FROM node:22.11.0-alpine3.20 AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat python3 make g++
WORKDIR /app

# Install pnpm directly via npm to avoid corepack signature verification issues
RUN npm install -g pnpm@10.13.1

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Re-install sqlite3 with npm to ensure the native binding is built and located correctly
# This replaces the pnpm symlink with a concrete folder, fixing the "Could not locate bindings" error
RUN npm uninstall sqlite3 && npm install sqlite3 --build-from-source

FROM node:22.11.0-alpine3.20 AS builder
WORKDIR /app
RUN npm install -g pnpm@10.13.1

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Disable telemetry during the build.
ENV NEXT_TELEMETRY_DISABLED 1

RUN pnpm run build

FROM node:22.11.0-alpine3.20 AS runner
WORKDIR /app

ENV NODE_ENV production
ENV NEXT_TELEMETRY_DISABLED 1
# Ensure local binaries (like concurrently) are on the PATH
ENV PATH="/app/node_modules/.bin:${PATH}"

# Install libc6-compat for potential runtime compatibility
RUN apk add --no-cache libc6-compat

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

RUN set -xe && mkdir -p /app/data && chown nextjs:nodejs /app/data

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# setup the cron
COPY --from=builder --chown=nextjs:nodejs /app/cron.js ./
COPY --from=builder --chown=nextjs:nodejs /app/email ./email
COPY --from=builder --chown=nextjs:nodejs /app/database ./database
COPY --from=builder --chown=nextjs:nodejs /app/.sequelizerc ./.sequelizerc
COPY --from=builder --chown=nextjs:nodejs /app/entrypoint.sh ./entrypoint.sh

# Copy production node_modules and package metadata from deps stage
COPY --from=deps --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./package.json
COPY --from=builder --chown=nextjs:nodejs /app/pnpm-lock.yaml ./pnpm-lock.yaml

USER nextjs

EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["concurrently", "node server.js", "node cron.js"]
