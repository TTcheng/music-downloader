# syntax=docker/dockerfile:1.7
# ============================================================================
# Deen 音乐下载器 — slim runtime image
# ----------------------------------------------------------------------------
# Multi-stage build:
#   1. builder  : python:3.11-slim-bookworm  — install pip deps into /opt/venv
#   2. runtime  : debian:bookworm-slim       — copies the Python toolchain
#                                               and pip site-packages from the
#                                               builder, plus the three API
#                                               binaries and the app source.
#
# Why Debian (not alpine): the three API binaries (ncm / qqmusic / kugou) are
# dynamically linked against glibc + libstdc++ + libpthread. Alpine uses musl
# libc and would force us to rebuild all three — out of scope.
#
# Why copy /usr/local from the builder instead of using Debian's python3.11:
#   the venv's pip-installed site-packages are built against the *builder's*
#   Python ABI. Mixing builder site-packages with Debian's python3.11 leads to
#   subtle symbol / LIBPL mismatches in C extensions (e.g. SQLAlchemy's
#   optional _sqlite speedups, lxml wheels). Copying /usr/local keeps a single
#   coherent Python install. Cost: ~30 MB vs the ~75 MB Debian-slim base.
#
# Expected total image size: ~250 MB
#   - debian:bookworm-slim     ~75 MB
#   - python toolchain (copy)  ~30 MB
#   - pip dependencies         ~30 MB
#   - three API binaries      ~141 MB
# ============================================================================

# ----------------------------------------------------------------------------
# Stage 1 — build Python dependency layer (cached & discarded)
# ----------------------------------------------------------------------------
# Override the mirrors at build time with `--build-arg`, e.g.:
#   docker build --build-arg APT_MIRROR=deb.debian.org --build-arg PIP_INDEX_URL=https://pypi.org/simple .
# Defaults below are the fastest mainland-China sources; leaving them as the
# default dramatically speeds up `docker build` on networks where the upstream
# Debian / PyPI CDNs are throttled.
ARG APT_MIRROR=mirrors.aliyun.com
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple

FROM python:3.11-slim-bookworm AS builder

# Re-declare the global ARGs inside the stage so they're visible to subsequent
# RUN/COPY. Pre-FROM `ARG` declarations are in a separate "global" scope and
# are NOT automatically inherited by stages; you must redeclare (with or
# without default) inside each stage that wants to use them. The default
# values from the global declaration carry through.
ARG APT_MIRROR
ARG PIP_INDEX_URL

# Point Debian's apt sources at the Aliyun mirror for both stages. The
# python:*-slim-bookworm base already ships an up-to-date sources.list
# pointing at deb.debian.org; we replace it once, before any apt-get runs.
# The Aliyun mirror is a full mirror of deb.debian.org so security/CVE
# coverage is identical.
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" \
            /etc/apt/sources.list.d/debian.sources; \
    fi; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" \
            /etc/apt/sources.list; \
    fi

# build-essential: only needed if a pure-Python package falls back to an sdist
# with a C extension. Cheap to keep; current requirements.txt doesn't need it
# but the layer costs ~150 MB at build time and is discarded afterward.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /install

# Copy only the requirements manifest first so the slow `pip install` layer
# caches independently of app source changes.
COPY requirements.txt ./

# Create the venv at a fixed path so the runtime stage can copy it directly.
# --no-cache-dir drops the wheel cache (~50 MB).
# Use the PyPI mirror (overridable via PIP_INDEX_URL build arg). We do NOT
# `pip install --upgrade pip` here: the venv already ships pip 24.0 which is
# sufficient for our deps, and skipping the upgrade avoids a transient 403
# on some Chinese PyPI mirrors when fetching the latest pip wheel.
RUN PIP_INDEX_URL=${PIP_INDEX_URL} python -m venv /opt/venv \
 && PIP_INDEX_URL=${PIP_INDEX_URL} /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ----------------------------------------------------------------------------
# Stage 2 — slim runtime
# ----------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="deen-music-downloader" \
      org.opencontainers.image.description="Flask-based multi-platform music downloader (Netease / QQ / Kugou)" \
      org.opencontainers.image.source="https://github.com/TTcheng/music-downloader" \
      org.opencontainers.image.licenses="MIT"

# Point Debian's apt sources at the Aliyun mirror (build-time only — runtime
# never invokes apt again). The sed is idempotent: if the file is already
# rewritten to the mirror, it stays; if not, we rewrite it.
ARG APT_MIRROR=mirrors.aliyun.com
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" \
            /etc/apt/sources.list.d/debian.sources; \
    fi; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" \
            /etc/apt/sources.list; \
    fi

# Runtime libs (verified via `ldd` on the bundled API binaries + Python's
# stdlib C extensions that need system libs at runtime):
#   libstdc++6    — C++ runtime required by the Go-rust API binaries.
#   libgcc-s1     — C++ exception-unwind helpers.
#   libsqlite3-0  — required by Python's built-in `_sqlite3` module (used by
#                   SQLAlchemy for the SQLite database). The `_sqlite3.so`
#                   module is linked against libsqlite3.so.0, which is NOT
#                   present in debian:bookworm-slim without this package.
#   ca-certificates — TLS to upstream music providers.
#   tini          — PID 1, signal forwarding, zombie reaping.
#   passwd        — provides `useradd` / `groupadd` for the non-root account.
#                   (The `shadow` source package name is NOT an apt binary
#                   package on Debian; the equivalent runtime is `passwd`.)
# No python3 here — Python comes from the builder's /usr/local (see below).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libstdc++6 \
        libgcc-s1 \
        libsqlite3-0 \
        ca-certificates \
        tini \
        passwd \
    ; \
    rm -rf /var/lib/apt/lists/*

# Copy the builder's Python toolchain (/usr/local) and venv (containing all
# site-packages). This keeps a single coherent Python ABI in the runtime —
# critical for any package that may later ship a C extension.
COPY --from=builder /usr/local /usr/local
COPY --from=builder /opt/venv   /opt/venv

# Trim stdlib bloat from the copied /usr/local. The python:3.11-slim-bookworm
# source ships the full CPython standard library tree including modules we
# never use (test suite, IDLE, tkinter, 2to3, pydoc data, turtledemo). None of
# them are imported by Flask / SQLAlchemy / APScheduler / requests / mutagen, so
# they are safe to drop. This removes ~50 MB from the runtime layer.
#
# - test/        : Python test suite
# - idlelib/     : IDLE editor
# - tkinter/     : Tk GUI bindings
# - turtledemo/  : turtle demo scripts
# - lib2to3/     : Python 2→3 converter
# - pydoc_data/  : pre-built doc index (we don't generate docs at runtime)
RUN rm -rf \
    /usr/local/lib/python3.11/test \
    /usr/local/lib/python3.11/idlelib \
    /usr/local/lib/python3.11/tkinter \
    /usr/local/lib/python3.11/turtledemo \
    /usr/local/lib/python3.11/lib2to3 \
    /usr/local/lib/python3.11/pydoc_data \
    /usr/local/include/python3.11 \
    /usr/local/share/man/man1/python3.11.1 \
    /usr/local/share/man/man1/python3.1 \
    /usr/local/lib/libpython3.11.a \
    /usr/local/share/doc/python3.11

# The builder venv's bin/python3 is an absolute symlink to /usr/bin/python3,
# which Debian-slim doesn't ship. Drop a compatibility symlink so the venv's
# interpreter resolves. The actual binary at /usr/local/bin/python3.11 is the
# real interpreter — this symlink just lets the venv find it through its own
# bin/python3 path.
RUN ln -sf /usr/local/bin/python3.11 /usr/bin/python3

ENV PATH="/opt/venv/bin:/usr/local/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# Non-root user. --system avoids UID collisions with host bind mounts and is
# the idiomatic choice for container service accounts.
RUN set -eux; \
    groupadd --system --gid 1000 deen; \
    useradd  --system --uid 1000 --gid deen --home-dir /data --shell /usr/sbin/nologin deen

# Workdir and persistent data layout.
WORKDIR /app
# /data   — persistent app state (SQLite DB, logs, ncm tmp)
# /downloads — large media files (kept on a separate mount by convention)
ENV APP_DATA_DIR=/data \
    DATA_DIR=/data \
    DOWNLOADS_DIR=/downloads
RUN mkdir -p /data /downloads && chown -R deen:deen /data /downloads

# Copy API binaries + app source last (changes most often → top of layer cache).
# --chown sets ownership on the COPIED contents only — the /app, /app/api,
# /app/core, /app/webapp directory entries themselves stay root-owned.
COPY --chown=deen:deen api/ /app/api/
COPY --chown=deen:deen core/ /app/core/
COPY --chown=deen:deen webapp/ /app/webapp/

# Make the three API binaries executable. They live in /app/api/ — the Python
# code looks them up via the project root (see core/providers/_proc.py), so no
# PATH symlink is needed.
RUN chmod +x /app/api/ncm-api-linux-x64 \
              /app/api/qqmusic-api-linux-x64 \
              /app/api/kugou_api_linux

# Grant the runtime `deen` user write access to /app. The app writes two things
# to paths under /app at runtime:
#   - /app/logs/webapp.log             (Flask logger via webapp/app.py)
#   - /app/logs/{ncm,qq,kugou}-api.log (subprocess API bridges via _proc.py)
#   - /app/api/web/...                 (ncm-api state files, written with
#                                      cwd=/app/api/ by spawn_protected)
# Pre-create these directories so the app's `mkdir(parents=True)` calls become
# no-ops, then chown /app recursively so the user can create new files.
RUN set -eux; \
    mkdir -p /app/logs /app/api/web; \
    chown -R deen:deen /app

USER deen

# Default web port. The web_port setting in the DB can override on first launch;
# mount a pre-seeded DB to bake in an override.
EXPOSE 45600

# Health check: probe /login (returns 200 even unauthenticated; / would just
# 302-redirect there, which urllib follows and then asserts against).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; \
r=urllib.request.urlopen('http://127.0.0.1:45600/login', timeout=2); \
sys.exit(0 if r.status==200 else 1)" || exit 1

# tini as PID 1 → Flask receives SIGTERM cleanly, runs its atexit hook, and the
# child API bridges (ncm/qq/kugou) get shut down via the PDEATHSIG prctl set
# during spawn.
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["sh", "-c", "exec python webapp/app.py --data-dir ${APP_DATA_DIR}"]