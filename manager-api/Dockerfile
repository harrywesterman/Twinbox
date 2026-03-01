FROM node:20-alpine
WORKDIR /app
RUN apk add --no-cache iputils
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src
EXPOSE 8080
CMD ["npm", "start"]
