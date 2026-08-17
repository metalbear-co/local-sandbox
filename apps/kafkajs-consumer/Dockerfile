# node:22-alpine is the node base already cached on sandbox machines; override
# with --build-arg BASE_IMAGE=... when it is not available.
ARG BASE_IMAGE=node:22-alpine
FROM ${BASE_IMAGE}
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY consumer.js .
ENTRYPOINT ["node", "consumer.js"]
