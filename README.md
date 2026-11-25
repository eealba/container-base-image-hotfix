# POC: actualizar la JVM de una imagen con `crane rebase`

Esta prueba compila una pequeña aplicación Java **una sola vez** y construye una
imagen con Eclipse Temurin 21.0.1. Después reemplaza las capas de esa base por
las de `eclipse-temurin:21-jre-alpine` sin volver a compilar ni reconstruir la
aplicación. El resultado se publica en un registry local y se ejecuta para
comparar la versión y el proveedor de Java, el sistema operativo y el SHA256 de
`App.class` antes y después.

## Requisitos

- Conexión a Internet para instalar herramientas y descargar las imágenes de
  Docker Hub. El rebase y las imágenes de la POC usan `127.0.0.1:5000`, sin
  credenciales de un registry externo.
- Puerto `5000` libre, espacio para las imágenes y `curl`.
- **macOS (Apple Silicon o Intel):** [Homebrew](https://brew.sh/). El script
  instala con Homebrew los comandos que falten cuando el prefijo permite
  escritura. Si Homebrew no puede instalarlos, el script usa MacPorts para
  instalar Go, Docker CLI y Colima; instala `crane` con Go y arranca Colima.
  MacPorts debe estar instalado previamente. La instalación de paquetes con
  MacPorts solicita autorización de administrador y no cambia propietarios ni
  permisos de Homebrew. En macOS con configuración Tier 3, Homebrew puede no
  ofrecer paquetes binarios.
- **Windows:** [WSL2](https://learn.microsoft.com/windows/wsl/install) con una
  distribución Linux y Docker Desktop configurado para usar contenedores Linux
  y con la [integración WSL](https://docs.docker.com/desktop/features/wsl/)
  habilitada para esa distribución. Dentro de WSL deben estar disponibles
  `docker`, `curl` y `crane`. Por ejemplo, con una instalación reciente de
  [Go](https://go.dev/doc/install), se puede instalar `crane` en WSL con:

  ```bash
  go install github.com/google/go-containerregistry/cmd/crane@latest
  export PATH="$PATH:$(go env GOPATH)/bin"
  ```

  Docker Desktop puede requerir una licencia según su uso y organización. El
  script también puede ejecutarse en Linux con esos mismos comandos y un
  daemon Docker operativo.

No se necesitan Java, Maven ni Gradle en el host. La compilación se ejecuta en
un contenedor JDK 21. En Windows, ejecuta los comandos siguientes **dentro de
WSL**, no en PowerShell ni CMD.

## Ejecución

Desde el directorio de este repositorio:

```bash
chmod +x run_poc.sh show_original.sh show_patched.sh
./run_poc.sh
```

El script crea o reutiliza el contenedor `jvm-rebase-poc-registry`, ligado
únicamente a `127.0.0.1:5000`, y publica:

- `127.0.0.1:5000/base-vieja:21` y `127.0.0.1:5000/base-nueva:21`;
- `127.0.0.1:5000/mi-microservicio:1.0.0`;
- `127.0.0.1:5000/mi-microservicio:1.0.0-patched`.

La salida muestra `Antes` y `Después`, incluyendo la versión exacta de Java y
el hash de `/app/App.class` en cada imagen. La ejecución falla si los hashes no
coinciden o si la versión de Java no cambia. Es seguro volver a ejecutar el
script: reutiliza el registry y actualiza las etiquetas. Si el puerto está
ocupado o existe un contenedor con el mismo nombre pero otra configuración, se
detiene sin modificarlo.

## Inspección de las imágenes locales

Después de ejecutar la POC, las imágenes también quedan disponibles en el
daemon local de Docker. Para inspeccionar cada una por separado:

```bash
./show_original.sh
./show_patched.sh
```

Cada script muestra el ID y la plataforma de la imagen, la salida de Java, los
archivos de `/app` y el SHA256 de `App.class`. No lista el filesystem completo.
Los scripts solo consultan y ejecutan las imágenes; no las eliminan ni
modifican.

## Limpieza

Cuando termines, elimina el registry y los datos almacenados en su contenedor:

```bash
docker rm -fv jvm-rebase-poc-registry
```

Las imágenes descargadas y construidas permanecen en la caché local de Docker;
puedes seguir inspeccionándolas con los dos scripts o eliminarlas con
`docker image rm` si ya no las necesitas. En macOS, `colima stop` detiene la
máquina virtual cuando no se utilice.

## Alcance y limitaciones

La etiqueta de la base nueva es mutable: la versión exacta descargada cambia con
el tiempo. La base antigua se incluye deliberadamente para demostración y no
debe usarse en producción. `crane rebase` sustituye capas, pero conserva la
configuración de la imagen original (por ejemplo, variables de entorno y
entrypoint); no actualiza automáticamente metadatos ni garantiza que dos bases
sean compatibles o estén libres de vulnerabilidades. En producción, fija
digests, comprueba la compatibilidad, ejecuta pruebas y análisis de seguridad,
y regenera las firmas y los SBOM pertinentes.
