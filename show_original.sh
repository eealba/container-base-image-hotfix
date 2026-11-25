#!/usr/bin/env bash
set -Eeuo pipefail

image="127.0.0.1:5000/mi-microservicio:1.0.0"

if ! docker info >/dev/null 2>&1; then
  echo "El daemon de Docker no está disponible." >&2
  exit 1
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "No se encuentra $image. Ejecuta ./run_poc.sh primero." >&2
  exit 1
fi

echo "Imagen: $image"
docker image inspect --format \
  'ID: {{.Id}}
Plataforma: {{.Os}}/{{.Architecture}}' "$image"

echo
echo "==> Java"
docker run --rm "$image"

echo
echo "==> Contenido de /app"
docker run --rm --entrypoint ls "$image" -lh /app

echo
echo "==> SHA256 de App.class"
docker run --rm --entrypoint sha256sum "$image" /app/App.class

