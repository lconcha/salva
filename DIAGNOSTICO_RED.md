# Diagnóstico de red — importador de DOI/PMID (SALVA)

## Contexto

El importador de artículos (pegar un DOI o PMID para pre-llenar el formulario)
necesita que el **servidor** donde corre SALVA (no la computadora del usuario)
tenga salida HTTPS hacia dos servicios externos:

- `api.crossref.org` (búsquedas por DOI)
- `eutils.ncbi.nlm.nih.gov` (búsquedas por PMID)

Actualmente cualquier búsqueda devuelve el mensaje genérico *"No se encontró
metadata para ese DOI/PMID"*. Ese mensaje aparece tanto si el DOI no existe
como si el servidor nunca pudo conectarse a Crossref/PubMed — así que no nos
dice cuál es la causa. Acabamos de agregar registro (`log`) al código para que
el motivo real quede en el log de Rails a partir de ahora, pero mientras se
despliega ese cambio (o si el log no es suficiente), estos pasos permiten
descartar cada causa posible directamente en el servidor.

**No se necesita ninguna llave/API key** para que esto funcione — ni Crossref
ni PubMed la requieren para búsquedas básicas. Se puede descartar esa
hipótesis desde el inicio.

## 1. Revisar el log de Rails (después de desplegar el cambio)

Después de intentar una búsqueda de DOI o PMID que falle, buscar en el log de
producción (típicamente `log/production.log`) una línea que empiece con
`MetadataFetcher:`:

```bash
grep -n "MetadataFetcher:" log/production.log | tail -20
```

Esa línea dirá exactamente qué pasó: un código HTTP (`HTTP 403`, `HTTP 500`,
etc.) o una excepción de Ruby (`SocketError`, `Errno::ECONNREFUSED`,
`Net::OpenTimeout`, `OpenSSL::SSL::SSLError`, etc.). La lista de la sección 5
explica qué significa cada una.

Si esa línea todavía no aparece en el log (porque el cambio no se ha
desplegado), seguir con las pruebas manuales de abajo.

## 2. Resolución de DNS

```bash
getent hosts api.crossref.org
getent hosts eutils.ncbi.nlm.nih.gov
```

Cada comando debe devolver una línea con una dirección IP. Si no devuelve
nada o da error, el servidor no puede resolver esos nombres — revisar el
`/etc/resolv.conf` del servidor (o del contenedor/apptainer si SALVA corre
dentro de uno) y el DNS que tenga configurado.

## 3. Conectividad HTTPS directa (sin pasar por la app)

Ejecutar **desde el mismo servidor/contenedor donde corre SALVA**, no desde
otra máquina:

```bash
curl -v --max-time 15 "https://api.crossref.org/works/10.1038/nature12373" -o /dev/null
curl -v --max-time 15 "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=25760099&retmode=json" -o /dev/null
```

Interpretación del resultado:

- **`HTTP/1.1 200`** al final → la conectividad funciona correctamente desde
  ese servidor. El problema no es de red; sería otra cosa (revisar el log de
  Rails, sección 1).
- **Se queda colgado y hace timeout** → típico de un firewall que bloquea el
  puerto 443 saliente hacia esos dominios, o de una red que exige salir por
  un proxy.
- **`Could not resolve host`** → problema de DNS (ver sección 2).
- **`Connection refused`** → algo intercepta o bloquea la conexión antes de
  llegar al destino.
- **Error de certificado / `SSL certificate problem`** → ver sección 5.

## 4. ¿Este servidor sale a Internet por un proxy?

Es común en redes institucionales (UNAM/campus) que la salida a Internet solo
funcione a través de un proxy HTTP configurado a nivel de sistema operativo.
Preguntar al equipo de red si ese es el caso para este servidor, y revisar si
existen variables de entorno como:

```bash
echo $http_proxy $https_proxy $HTTP_PROXY $HTTPS_PROXY
```

**Importante:** aunque esas variables existan a nivel de sistema, el código
actual de SALVA (`lib/salva/metadata_fetcher.rb`) **no las usa** — se conecta
directo con `Net::HTTP`, sin pasar por ningún proxy. Si el servidor
efectivamente requiere proxy para salir a Internet, avísennos: hay que
agregar soporte explícito de proxy en ese archivo (cambio sencillo, no
requiere gemas nuevas).

## 5. Errores de TLS/certificados

Si el `curl` de la sección 3 falla por certificado (`SSL certificate
problem`, `unable to get local issuer certificate`), probablemente el
almacén de certificados raíz (CA bundle) del sistema operativo o del
contenedor está desactualizado o incompleto. En Debian/Ubuntu:

```bash
apt-get install --reinstall ca-certificates
update-ca-certificates
```

Si SALVA corre dentro de un contenedor (apptainer/singularity/docker), el
problema puede estar en el CA bundle *dentro* de la imagen del contenedor,
no en el host — hay que revisar cuál de los dos está haciendo la conexión
saliente.

## 6. Resumen de qué reportarnos

Si después de estos pasos sigue sin funcionar, por favor compartan:

1. La salida completa de los dos `curl -v` de la sección 3.
2. La salida de `getent hosts` de la sección 2.
3. Si existe o no un proxy obligatorio para salida a Internet (sección 4).
4. Las líneas `MetadataFetcher:` del log, si ya aparecen (sección 1).

Con eso podemos saber exactamente si el ajuste necesario es de red/firewall
(fuera de nuestro alcance, les corresponde a ustedes) o de código (nuestro).
