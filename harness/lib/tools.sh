# shellcheck shell=bash
# Installs pinned CLI tools into harness/.bin on first use (Linux and macOS,
# amd64 and arm64). No root needed. Source after common.sh.

TERRAFORM_VERSION=1.9.8
KUBECTL_VERSION=1.31.2
KUBECONFORM_VERSION=0.6.7
KWOK_VERSION=0.6.1
KYVERNO_VERSION=1.13.2
KIND_VERSION=0.24.0
KUSTOMIZE_VERSION=5.4.3

_os() { uname -s | tr '[:upper:]' '[:lower:]'; }
_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) uname -m ;; esac; }

_fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

_install_tool() {
  local name=$1 os arch tmp
  os=$(_os); arch=$(_arch); tmp=$(mktemp -d)
  case "$name" in
    terraform)
      _fetch "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${os}_${arch}.zip" "$tmp/tf.zip" &&
        python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract("terraform", sys.argv[2])' "$tmp/tf.zip" "$BIN_DIR" ;;
    kubectl)
      _fetch "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl" "$BIN_DIR/kubectl" ;;
    kubeconform)
      _fetch "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz" "$tmp/kc.tgz" &&
        tar -xzf "$tmp/kc.tgz" -C "$BIN_DIR" kubeconform ;;
    kwokctl|kwok)
      _fetch "https://github.com/kubernetes-sigs/kwok/releases/download/v${KWOK_VERSION}/${name}-${os}-${arch}" "$BIN_DIR/$name" ;;
    kyverno)
      local karch; karch=$([ "$arch" = amd64 ] && echo x86_64 || echo arm64)
      _fetch "https://github.com/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}/kyverno-cli_v${KYVERNO_VERSION}_${os}_${karch}.tar.gz" "$tmp/ky.tgz" &&
        tar -xzf "$tmp/ky.tgz" -C "$BIN_DIR" kyverno ;;
    kustomize)
      _fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_${os}_${arch}.tar.gz" "$tmp/kz.tgz" &&
        tar -xzf "$tmp/kz.tgz" -C "$BIN_DIR" kustomize ;;
    kind)
      _fetch "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-${os}-${arch}" "$BIN_DIR/kind" ;;
    *) log "don't know how to install $name"; rm -rf "$tmp"; return 1 ;;
  esac
  local rc=$?
  rm -rf "$tmp"
  [ $rc -eq 0 ] && chmod +x "$BIN_DIR/$name"
  return $rc
}

# need_tools NAME... — installs any of the named tools that are missing from
# harness/.bin. Tools already on PATH elsewhere are not reused, so every run
# uses the pinned versions above.
need_tools() {
  local t
  for t in "$@"; do
    [ -x "$BIN_DIR/$t" ] && continue
    log "installing $t into harness/.bin"
    _install_tool "$t" || { log "failed to install $t"; return 1; }
  done
}
