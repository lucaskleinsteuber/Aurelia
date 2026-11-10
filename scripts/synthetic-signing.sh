# Sourced by tests: a minisign-compatible signer made of openssl, so that update checks can sign
# synthetic releases with a throwaway key on computers without minisign. It never touches the
# owner's key. Needs openssl 1.1.1 or newer (on macOS the one from Homebrew).

# Prefers Homebrew's openssl on macOS, whose own LibreSSL cannot sign Ed25519 this way.
if [ -x /opt/homebrew/opt/openssl@3/bin/openssl ]; then PATH="/opt/homebrew/opt/openssl@3/bin:$PATH"; fi
if [ -x /usr/local/opt/openssl@3/bin/openssl ]; then PATH="/usr/local/opt/openssl@3/bin:$PATH"; fi

# synthetic_signing_key <folder> creates a key there and prints its public key in minisign's form.
synthetic_signing_key() {
  local folder=$1
  openssl genpkey -algorithm ed25519 -outform DER -out "$folder/synthetic-key.der" 2>/dev/null
  openssl pkey -inform DER -in "$folder/synthetic-key.der" -pubout -outform DER -out "$folder/synthetic-public.der"
  head -c 8 /dev/urandom > "$folder/synthetic-key.id"
  { printf Ed; cat "$folder/synthetic-key.id"; tail -c 32 "$folder/synthetic-public.der"; } | base64 | tr -d '\n'
}

# synthetic_sign <folder> <file> <trusted comment> writes <file>.minisig with the key in <folder>:
# the prehashed signature and the signature over it and the trusted comment, as minisign does.
synthetic_sign() {
  local folder=$1 file=$2 comment=$3
  openssl dgst -blake2b512 -binary "$file" > "$folder/synthetic-hash"
  openssl pkeyutl -sign -keyform DER -inkey "$folder/synthetic-key.der" -rawin \
    -in "$folder/synthetic-hash" -out "$folder/synthetic-signature"
  { cat "$folder/synthetic-signature"; printf '%s' "$comment"; } > "$folder/synthetic-global-input"
  openssl pkeyutl -sign -keyform DER -inkey "$folder/synthetic-key.der" -rawin \
    -in "$folder/synthetic-global-input" -out "$folder/synthetic-global"
  {
    echo 'untrusted comment: synthetic test signature'
    { printf ED; cat "$folder/synthetic-key.id" "$folder/synthetic-signature"; } | base64 | tr -d '\n'
    echo
    echo "trusted comment: $comment"
    base64 < "$folder/synthetic-global" | tr -d '\n'
    echo
  } > "$file.minisig"
}
