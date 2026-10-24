# Fixture para AC-16..AC-18 de tests/onboarding_test.sh con el pack ficticio acme (datos inventados).
# Un pack real aporta el suyo (misma forma) y se pasa con FIXTURE_SH=<pack>/tests/fixtures/ac18.sh.
FIXTURE_PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_PACK_NAME="$(grep '^nombre:' "$FIXTURE_PACK_DIR/pack.yaml" | awk '{print $2}')"
FIXTURE_ORG="acme-org"
FIXTURE_REPO_NAME="api-acme"
FIXTURE_REPO_FULL="acme-org/api-acme"
FIXTURE_EXPECTED_BOARD="alfa"
