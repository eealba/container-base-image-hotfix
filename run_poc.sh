#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Error en la POC (línea $LINENO)." >&2' ERR

registry_container="jvm-rebase-poc-registry"
registry="127.0.0.1:5000"
old_upstream="eclipse-temurin:21.0.1_12-jre-alpine"
new_upstream="eclipse-temurin:21-jre-alpine"
jdk="eclipse-temurin:21-jdk-alpine"
old_base="$registry/base-vieja:21"
new_base="$registry/base-nueva:21"
original="$registry/mi-microservicio:1.0.0"
patched="$registry/mi-microservicio:1.0.0-patched"

case "$(uname -s)" in
  Darwin)
    brew_can_install=false
    if command -v brew >/dev/null 2>&1; then
      if brew_prefix="$(brew --prefix 2>/dev/null)"; then
        brew_libexec="$brew_prefix/libexec"
        if [ ! -d "$brew_libexec" ] || [ -w "$brew_libexec" ]; then
          brew_can_install=true
        fi
      fi
    fi

    if ! command -v crane >/dev/null 2>&1 && [ "$brew_can_install" = true ]; then
      brew install crane || echo "Homebrew no pudo instalar crane; se probará MacPorts." >&2
    fi
    if ! command -v docker >/dev/null 2>&1 && [ "$brew_can_install" = true ]; then
      brew install docker || echo "Homebrew no pudo instalar docker; se probará MacPorts." >&2
    fi
    if ! docker info >/dev/null 2>&1 && ! command -v colima >/dev/null 2>&1 && [ "$brew_can_install" = true ]; then
      brew install colima || echo "Homebrew no pudo instalar colima; se probará MacPorts." >&2
    fi

    macports_packages=()
    if ! command -v crane >/dev/null 2>&1 && ! command -v go >/dev/null 2>&1; then
      macports_packages+=(go)
    fi
    if ! command -v docker >/dev/null 2>&1; then
      macports_packages+=(docker)
    fi
    if ! docker info >/dev/null 2>&1 && ! command -v colima >/dev/null 2>&1; then
      macports_packages+=(colima)
    fi

    if [ "${#macports_packages[@]}" -gt 0 ]; then
      if ! command -v port >/dev/null 2>&1; then
        echo "Faltan dependencias y Homebrew no puede instalarlas. Instala MacPorts para tu versión de macOS desde https://www.macports.org/install.php y vuelve a ejecutar la POC." >&2
        exit 1
      fi
      echo "==> Instalando dependencias con MacPorts (sin cambiar propietarios de Homebrew)"
      sudo -A port selfupdate
      sudo -A port install "${macports_packages[@]}"
      hash -r
    fi

    if ! command -v crane >/dev/null 2>&1; then
      go_bin="$(go env GOBIN)"
      if [ -z "$go_bin" ]; then
        go_bin="$(go env GOPATH)/bin"
      fi
      if ! go install github.com/google/go-containerregistry/cmd/crane@latest; then
        echo "No se pudo instalar crane con Go." >&2
        exit 1
      fi
      export PATH="$go_bin:$PATH"
    fi
    if ! command -v docker >/dev/null 2>&1; then
      echo "No se encontró el comando docker después de instalar las dependencias." >&2
      exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
      if ! command -v colima >/dev/null 2>&1; then
        echo "Docker no tiene un daemon activo y Colima no está instalado." >&2
        exit 1
      fi
      if ! colima start; then
        echo "No se pudo iniciar Colima." >&2
        exit 1
      fi
    fi
    ;;
  Linux)
    # Windows is supported through WSL2 with Docker Desktop's WSL integration.
    for command in docker crane; do
      if ! command -v "$command" >/dev/null 2>&1; then
        echo "Falta $command. Consulta los requisitos de WSL2/Linux en el README." >&2
        exit 1
      fi
    done
    ;;
  *)
    echo "Usa macOS o ejecuta este script en WSL2 (Windows)." >&2
    exit 1
    ;;
esac

if ! docker info >/dev/null 2>&1; then
  echo "El daemon de Docker no está disponible. Comprueba Colima o la integración de Docker con WSL2." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Se necesita curl para comprobar el registry local." >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "==> Preparando registry local en 127.0.0.1:5000"
if docker container inspect "$registry_container" >/dev/null 2>&1; then
  image="$(docker inspect --format '{{.Config.Image}}' "$registry_container")"
  binding="$(docker inspect --format '{{(index (index .HostConfig.PortBindings "5000/tcp") 0).HostIp}}:{{(index (index .HostConfig.PortBindings "5000/tcp") 0).HostPort}}' "$registry_container" 2>/dev/null || true)"
  if [ "$image" != "registry:2" ] || [ "$binding" != "127.0.0.1:5000" ]; then
    echo "El contenedor $registry_container ya existe con otra configuración; no se modificará." >&2
    exit 1
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$registry_container")" != "true" ]; then
    docker start "$registry_container" >/dev/null
  fi
else
  docker run -d --name "$registry_container" -p 127.0.0.1:5000:5000 registry:2 >/dev/null
fi

ready=false
attempt=0
while [ "$attempt" -lt 10 ]; do
  if curl --noproxy '*' -fsS http://127.0.0.1:5000/v2/ >/dev/null 2>&1; then
    ready=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$ready" != true ]; then
  echo "El registry no responde en 127.0.0.1:5000; revisa el contenedor y el puerto." >&2
  exit 1
fi

cat > "$workdir/App.java" <<'JAVA'
public class App {
    public static void main(String[] args) {
        System.out.println("java.version=" + System.getProperty("java.version"));
        System.out.println("java.vendor=" + System.getProperty("java.vendor"));
        System.out.println("os.name=" + System.getProperty("os.name"));
    }
}
JAVA

echo "==> Compilando App.java una sola vez en un contenedor JDK 21"
docker run --rm -i --entrypoint sh "$jdk" -c \
  'cat > /tmp/App.java && javac /tmp/App.java && cat /tmp/App.class' \
  < "$workdir/App.java" > "$workdir/App.class"

echo "==> Copiando las bases al registry local"
docker pull "$old_upstream"
docker tag "$old_upstream" "$old_base"
docker push "$old_base"
docker pull "$new_upstream"
docker tag "$new_upstream" "$new_base"
docker push "$new_base"

cat > "$workdir/Dockerfile" <<EOF
FROM $old_base
COPY App.class /app/App.class
ENTRYPOINT ["java", "-cp", "/app", "App"]
EOF

echo "==> Construyendo y ejecutando la imagen original"
docker build --pull --provenance=false -t "$original" "$workdir"
docker push "$original"
before="$(docker run --rm "$original")"
before_hash="$(docker run --rm --entrypoint sha256sum "$original" /app/App.class)"
printf '\nAntes:\n%s\n%s\n' "$before" "$before_hash"

echo "==> Aplicando crane rebase sin recompilar la aplicación"
crane rebase --insecure --old_base "$old_base" --new_base "$new_base" \
  --tag "$patched" "$original"
docker pull "$patched"
after="$(docker run --rm "$patched")"
after_hash="$(docker run --rm --entrypoint sha256sum "$patched" /app/App.class)"
printf '\nDespués:\n%s\n%s\n' "$after" "$after_hash"

if [ "$before_hash" != "$after_hash" ]; then
  echo "ERROR: App.class cambió durante el rebase." >&2
  exit 1
fi
before_version="$(printf '%s\n' "$before" | grep '^java.version=')"
after_version="$(printf '%s\n' "$after" | grep '^java.version=')"
if [ "$before_version" = "$after_version" ]; then
  echo "ERROR: la versión de Java no cambió." >&2
  exit 1
fi
printf '\nValidación correcta: JVM actualizada y SHA256 de App.class idéntico.\n'
printf 'Limpieza del registry y sus datos: docker rm -fv %s\n' "$registry_container"
