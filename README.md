# openappsec-nginx-attachment

Builds the [open-appsec NGINX attachment](https://github.com/openappsec/attachment)
(`libngx_module.so` + its `libosrc_*`/`libshmem_ipc*` runtime libraries) for a chosen
upstream NGINX version, and publishes a minimal `initContainer` image:

    ghcr.io/k8stooling/openappsec-nginx-attachment:nginx-<version>

The image (busybox) contains the libraries in `/openappsec/lib/`; by default it runs
`cp -fv /openappsec/lib/*.so /opt/openappsec-attachment/`.

The build uses `--with-compat` and the same flags as F5 `nginx/nginx-ingress` (minus the
F5-proprietary modules), and the `Dockerfile` smoke-tests the result: no unresolved
`ldd` entries, and `nginx -t` with `load_module` must succeed or the build fails.
All `.so` files get `RUNPATH=$ORIGIN`, so the dependencies resolve from the same
directory and **no `LD_LIBRARY_PATH` is needed** (check: `readelf -d libngx_module.so`).

## 1. Find the target NGINX version / OS

```sh
kubectl exec -n nginx-ingress deploy/nginx-ingress-controller -- nginx -V
kubectl exec -n nginx-ingress deploy/nginx-ingress-controller -- cat /etc/os-release
```

Match the Debian suite (`trixie-slim` / `bookworm-slim`) and the NGINX version to the output
(`built by gcc`, `built with OpenSSL` should agree with the build image).

## 2. Build a new version

GitHub → Actions → **build** → *Run workflow*, or:

```sh
gh workflow run build.yml -f nginx_version=1.31.8 -f attachment_ref=main \
   -f debian_suite=trixie-slim -f push_image=true
```

Tags pushed: `nginx-<ver>`, `nginx-<ver>-<attachment_ref>`, `nginx-<ver>-<run_number>`.
The `.so` files are also uploaded as artifact `openappsec-nginx-<ver>`.

Local build:

```sh
docker build --build-arg NGINX_VERSION=1.31.8 -t openappsec-nginx-attachment .
```

## 3. F5 NGINX Ingress Helm values

```yaml
controller:
  enableSnippets: true
  mainSnippets: |
    load_module /opt/openappsec-attachment/libngx_module.so;
    # Only needed if you build without RUNPATH=$ORIGIN:
    # env LD_LIBRARY_PATH=/opt/openappsec-attachment;

  initContainers:
    - name: openappsec-attachment
      image: ghcr.io/k8stooling/openappsec-nginx-attachment:nginx-1.31.8
      volumeMounts:
        - name: openappsec-attachment
          mountPath: /opt/openappsec-attachment

  volumes:
    - name: openappsec-attachment
      emptyDir: {}
    - name: shm
      emptyDir:
        medium: Memory

  volumeMounts:
    - name: openappsec-attachment
      mountPath: /opt/openappsec-attachment
      readOnly: true
    - name: shm
      mountPath: /dev/shm

  extraContainers:
    - name: openappsec-agent
      image: ghcr.io/openappsec/agent:latest
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
```

The agent needs its own configuration (e.g. `registered-server` / token / `--standalone`
settings) — see the open-appsec docs. Value key names (`initContainers`, `volumes`,
`volumeMounts`, `extraContainers`) vary between chart versions; check your chart's
`values.yaml`.

## License

Apache-2.0 (open-appsec/attachment is Apache-2.0 as well).
