#!/bin/bash
# easy_subs_firebase - Standalone Deployment Script
# This script will help you deploy the Firebase functions for this package to a new or existing project.

set -e

echo "=========================================================="
echo "🚀 Starting standalone deployment of easy_subs_firebase"
echo "=========================================================="
echo ""

# Identify our source directory early (required for local state files)
DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR="$(mktemp -d /tmp/easy-subs-firebase-XXXXXX)"
STATE_FILE="$DIR/.deploy_state"

resolve_optional_value() {
  local input="$1"
  local saved_value="$2"

  if [ -z "$input" ]; then
    printf '%s' "$saved_value"
  elif [ "$input" = "skip" ] || [ "$input" = "-" ]; then
    printf ''
  else
    printf '%s' "$input"
  fi
}

escape_newlines() {
  printf '%s' "$1" | awk 'BEGIN { ORS="" } { printf "%s\\n", $0 }' | sed 's/\\n$//'
}

unescape_newlines() {
  printf '%s' "$1" | perl -0pe 's/\\\\n/\n/g; s/\\n/\n/g'
}

mask_secret() {
  local value="$1"
  if [ -z "$value" ]; then
    printf '(empty)'
  elif [ ${#value} -le 4 ]; then
    printf '****'
  else
    printf '****%s' "${value: -4}"
  fi
}

validate_apple_server_api_values() {
  local has_any="false"
  local issuer_ok="true"
  local key_ok="true"
  local bundle_ok="true"
  local private_ok="true"

  if [ -n "$APPLE_ISSUER_ID" ] || [ -n "$APPLE_KEY_ID" ] || [ -n "$APPLE_PRIVATE_KEY" ] || [ -n "$APPLE_BUNDLE_ID" ]; then
    has_any="true"
  fi

  if [ "$has_any" != "true" ]; then
    return
  fi

  echo ""
  echo "🔎 Validating Apple Server API variables..."

  if [ -z "$APPLE_ISSUER_ID" ] || [ -z "$APPLE_KEY_ID" ] || [ -z "$APPLE_PRIVATE_KEY" ] || [ -z "$APPLE_BUNDLE_ID" ]; then
    echo "❌ Apple Server API validation failed: issuer/key/private key/bundle must all be set together."
    exit 1
  fi

  if [[ ! "$APPLE_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    issuer_ok="false"
  fi

  if [[ ! "$APPLE_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    key_ok="false"
  fi

  if [[ ! "$APPLE_BUNDLE_ID" =~ ^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$ ]]; then
    bundle_ok="false"
  fi

  if [[ "$APPLE_PRIVATE_KEY" =~ ^[a-fA-F0-9]{32}$ ]]; then
    private_ok="false"
  fi

  if [[ "$APPLE_PRIVATE_KEY" != *"-----BEGIN PRIVATE KEY-----"* ]] || [[ "$APPLE_PRIVATE_KEY" != *"-----END PRIVATE KEY-----"* ]]; then
    private_ok="false"
  fi

  if ! printf '%s' "$APPLE_PRIVATE_KEY" | grep -q $'\n'; then
    private_ok="false"
  fi

  if [ "$issuer_ok" != "true" ]; then
    echo "❌ APPLE_ISSUER_ID invalid format (expected UUID)."
    exit 1
  fi

  if [ "$key_ok" != "true" ]; then
    echo "❌ APPLE_KEY_ID invalid format (expected 10 uppercase alphanumeric chars)."
    exit 1
  fi

  if [ "$bundle_ok" != "true" ]; then
    echo "❌ APPLE_BUNDLE_ID invalid format (expected reverse-domain, e.g. com.mycompany.app)."
    exit 1
  fi

  if [ "$private_ok" != "true" ]; then
    echo "❌ APPLE_PRIVATE_KEY invalid format (expected full PEM with BEGIN/END and multiline content)."
    exit 1
  fi

  if command -v openssl > /dev/null 2>&1; then
    local key_tmp_file
    key_tmp_file="$(mktemp /tmp/apple-key-XXXXXX.p8)"
    printf '%s\n' "$APPLE_PRIVATE_KEY" > "$key_tmp_file"
    if ! openssl pkey -in "$key_tmp_file" -noout > /dev/null 2>&1; then
      rm -f "$key_tmp_file"
      echo "❌ APPLE_PRIVATE_KEY could not be parsed by openssl."
      exit 1
    fi
    rm -f "$key_tmp_file"
  fi

  echo "✅ Apple Server API variables passed validation."
}

show_current_values() {
  echo ""
  echo "📋 Current deploy values:"
  echo "1) PROJECT_ID=${PROJECT_ID:-<empty>}"
  echo "2) APPLE_SHARED_SECRET=$(mask_secret "$APPLE_SHARED_SECRET")"
  echo "3) GOOGLE_PLAY_PACKAGE_NAME=${GOOGLE_PLAY_PACKAGE_NAME:-<empty>}"
  echo "4) APPLE_ISSUER_ID=${APPLE_ISSUER_ID:-<empty>}"
  echo "5) APPLE_KEY_ID=${APPLE_KEY_ID:-<empty>}"
  if [ -n "$APPLE_PRIVATE_KEY" ]; then
    echo "6) APPLE_PRIVATE_KEY=[saved]"
  else
    echo "6) APPLE_PRIVATE_KEY=<empty>"
  fi
  echo "7) APPLE_BUNDLE_ID=${APPLE_BUNDLE_ID:-<empty>}"
}

prompt_project_id() {
  if [ -n "$PROJECT_ID" ]; then
    echo "📝 Firebase Project ID [${PROJECT_ID}] (press Enter to keep):"
    read -r -p "> " PROJECT_ID_INPUT
    PROJECT_ID="${PROJECT_ID_INPUT:-$PROJECT_ID}"
  else
    echo "📝 Please enter your Firebase Project ID (e.g., my-project-123):"
    read -r -p "> " PROJECT_ID
  fi
}

prompt_apple_shared_secret() {
  if [ -n "$APPLE_SHARED_SECRET" ]; then
    read -r -p "APPLE_SHARED_SECRET [saved] (press Enter to keep): " APPLE_SHARED_SECRET_INPUT
    APPLE_SHARED_SECRET="${APPLE_SHARED_SECRET_INPUT:-$APPLE_SHARED_SECRET}"
  else
    read -r -p "APPLE_SHARED_SECRET (App Store Connect Shared Secret): " APPLE_SHARED_SECRET
  fi
}

prompt_google_play_package_name() {
  if [ -n "$GOOGLE_PLAY_PACKAGE_NAME" ]; then
    read -r -p "GOOGLE_PLAY_PACKAGE_NAME [${GOOGLE_PLAY_PACKAGE_NAME}] (press Enter to keep): " GOOGLE_PLAY_PACKAGE_NAME_INPUT
    GOOGLE_PLAY_PACKAGE_NAME="${GOOGLE_PLAY_PACKAGE_NAME_INPUT:-$GOOGLE_PLAY_PACKAGE_NAME}"
  else
    read -r -p "GOOGLE_PLAY_PACKAGE_NAME (e.g. com.your.app): " GOOGLE_PLAY_PACKAGE_NAME
  fi
}

prompt_apple_issuer_id() {
  if [ -n "$APPLE_ISSUER_ID" ]; then
    read -r -p "APPLE_ISSUER_ID [${APPLE_ISSUER_ID}] (Enter to keep / type 'skip' or '-' to clear): " APPLE_ISSUER_ID_INPUT
    APPLE_ISSUER_ID="$(resolve_optional_value "$APPLE_ISSUER_ID_INPUT" "$APPLE_ISSUER_ID")"
  else
    read -r -p "APPLE_ISSUER_ID (optional): " APPLE_ISSUER_ID
  fi
}

prompt_apple_key_id() {
  if [ -n "$APPLE_KEY_ID" ]; then
    read -r -p "APPLE_KEY_ID [${APPLE_KEY_ID}] (Enter to keep / type 'skip' or '-' to clear): " APPLE_KEY_ID_INPUT
    APPLE_KEY_ID="$(resolve_optional_value "$APPLE_KEY_ID_INPUT" "$APPLE_KEY_ID")"
  else
    read -r -p "APPLE_KEY_ID (optional): " APPLE_KEY_ID
  fi
}

prompt_apple_private_key() {
  echo "APPLE_PRIVATE_KEY source options:"
  echo "1) Provide .p8 file path"
  echo "2) Paste key manually"
  if [ -n "$APPLE_PRIVATE_KEY" ]; then
    echo "3) Keep current saved value"
    echo "4) Clear value"
    read -r -p "Select option [3]: " APPLE_KEY_INPUT_MODE
    APPLE_KEY_INPUT_MODE="${APPLE_KEY_INPUT_MODE:-3}"
  else
    echo "3) Leave empty"
    read -r -p "Select option [1]: " APPLE_KEY_INPUT_MODE
    APPLE_KEY_INPUT_MODE="${APPLE_KEY_INPUT_MODE:-1}"
  fi

  case "$APPLE_KEY_INPUT_MODE" in
    1)
      read -r -p "Path to .p8 file (optional): " APPLE_PRIVATE_KEY_PATH
      if [ -n "$APPLE_PRIVATE_KEY_PATH" ]; then
        if [ ! -f "$APPLE_PRIVATE_KEY_PATH" ]; then
          echo "❌ Error: .p8 file not found at $APPLE_PRIVATE_KEY_PATH"
          exit 1
        fi
        APPLE_PRIVATE_KEY="$(cat "$APPLE_PRIVATE_KEY_PATH")"
      else
        APPLE_PRIVATE_KEY=""
      fi
      ;;
    2)
      read -r -p "APPLE_PRIVATE_KEY (paste full PEM, optional): " APPLE_PRIVATE_KEY
      ;;
    3)
      if [ -z "$APPLE_PRIVATE_KEY" ]; then
        APPLE_PRIVATE_KEY=""
      fi
      ;;
    4)
      if [ -n "$APPLE_PRIVATE_KEY" ]; then
        APPLE_PRIVATE_KEY=""
      else
        echo "❌ Invalid option for APPLE_PRIVATE_KEY source"
        exit 1
      fi
      ;;
    *)
      echo "❌ Invalid option for APPLE_PRIVATE_KEY source"
      exit 1
      ;;
  esac
}

prompt_apple_bundle_id() {
  if [ -n "$APPLE_BUNDLE_ID" ]; then
    read -r -p "APPLE_BUNDLE_ID [${APPLE_BUNDLE_ID}] (Enter to keep / type 'skip' or '-' to clear): " APPLE_BUNDLE_ID_INPUT
    APPLE_BUNDLE_ID="$(resolve_optional_value "$APPLE_BUNDLE_ID_INPUT" "$APPLE_BUNDLE_ID")"
  else
    read -r -p "APPLE_BUNDLE_ID (optional, e.g. com.mycompany.chefed): " APPLE_BUNDLE_ID
  fi
}

review_and_edit_saved_values() {
  local has_all_saved="false"
  local change_choice=""
  local selected_field=""
  local edit_another_choice=""
  local edited_value="false"

  if [ -n "$PROJECT_ID" ] && \
     [ -n "$APPLE_SHARED_SECRET" ] && \
     [ -n "$GOOGLE_PLAY_PACKAGE_NAME" ] && \
     [ -n "$APPLE_ISSUER_ID" ] && \
     [ -n "$APPLE_KEY_ID" ] && \
     [ -n "$APPLE_PRIVATE_KEY" ] && \
     [ -n "$APPLE_BUNDLE_ID" ]; then
    has_all_saved="true"
  fi

  if [ "$has_all_saved" != "true" ]; then
    return
  fi

  while true; do
    show_current_values
    echo ""
    read -r -p "Do you want to change any value before deploy? [y/N/all]: " change_choice

    case "$change_choice" in
      all|ALL|All)
        prompt_project_id
        prompt_apple_shared_secret
        prompt_google_play_package_name
        prompt_apple_issuer_id
        prompt_apple_key_id
        prompt_apple_private_key
        prompt_apple_bundle_id
        USE_SAVED_VALUES_WITHOUT_REPROMPT="true"
        break
        ;;
      y|Y|yes|YES)
        edited_value="false"
        echo "Select a number to change:"
        echo "1) PROJECT_ID"
        echo "2) APPLE_SHARED_SECRET"
        echo "3) GOOGLE_PLAY_PACKAGE_NAME"
        echo "4) APPLE_ISSUER_ID"
        echo "5) APPLE_KEY_ID"
        echo "6) APPLE_PRIVATE_KEY"
        echo "7) APPLE_BUNDLE_ID"
        echo "8) Change all values"
        read -r -p "Selection [1-8]: " selected_field
        case "$selected_field" in
          1)
            prompt_project_id
            edited_value="true"
            ;;
          2)
            prompt_apple_shared_secret
            edited_value="true"
            ;;
          3)
            prompt_google_play_package_name
            edited_value="true"
            ;;
          4)
            prompt_apple_issuer_id
            edited_value="true"
            ;;
          5)
            prompt_apple_key_id
            edited_value="true"
            ;;
          6)
            prompt_apple_private_key
            edited_value="true"
            ;;
          7)
            prompt_apple_bundle_id
            edited_value="true"
            ;;
          8)
            prompt_project_id
            prompt_apple_shared_secret
            prompt_google_play_package_name
            prompt_apple_issuer_id
            prompt_apple_key_id
            prompt_apple_private_key
            prompt_apple_bundle_id
            edited_value="true"
            ;;
          *)
            echo "❌ Invalid selection. Choose a number between 1 and 8."
            ;;
        esac

        if [ "$edited_value" = "true" ]; then
          read -r -p "Do you want to edit another value? [y/N]: " edit_another_choice
          case "$edit_another_choice" in
            y|Y|yes|YES)
              ;;
            *)
              USE_SAVED_VALUES_WITHOUT_REPROMPT="true"
              break
              ;;
          esac
        fi
        ;;
      *)
        USE_SAVED_VALUES_WITHOUT_REPROMPT="true"
        break
        ;;
    esac
  done
}

USE_SAVED_VALUES_WITHOUT_REPROMPT="false"

if ! command -v firebase &> /dev/null
then
    echo "❌ Error: 'firebase-tools' is not installed."
    echo "💡 Install it by running: npm install -g firebase-tools"
    exit 1
fi

echo "✅ Firebase CLI detected."

# Load previous values if available
LAST_PROJECT_ID=""
LAST_APPLE_SHARED_SECRET=""
LAST_GOOGLE_PLAY_PACKAGE_NAME=""
LAST_APPLE_ISSUER_ID=""
LAST_APPLE_KEY_ID=""
LAST_APPLE_PRIVATE_KEY=""
LAST_APPLE_BUNDLE_ID=""
if [ -f "$STATE_FILE" ]; then
  LAST_PROJECT_ID="$(grep -E '^PROJECT_ID=' "$STATE_FILE" | sed 's/^PROJECT_ID=//')"
  LAST_APPLE_SHARED_SECRET="$(grep -E '^APPLE_SHARED_SECRET=' "$STATE_FILE" | sed 's/^APPLE_SHARED_SECRET=//')"
  LAST_GOOGLE_PLAY_PACKAGE_NAME="$(grep -E '^GOOGLE_PLAY_PACKAGE_NAME=' "$STATE_FILE" | sed 's/^GOOGLE_PLAY_PACKAGE_NAME=//')"
  LAST_APPLE_ISSUER_ID="$(grep -E '^APPLE_ISSUER_ID=' "$STATE_FILE" | sed 's/^APPLE_ISSUER_ID=//')"
  LAST_APPLE_KEY_ID="$(grep -E '^APPLE_KEY_ID=' "$STATE_FILE" | sed 's/^APPLE_KEY_ID=//')"
  LAST_APPLE_PRIVATE_KEY="$(grep -E '^APPLE_PRIVATE_KEY=' "$STATE_FILE" | sed 's/^APPLE_PRIVATE_KEY=//')"
  LAST_APPLE_PRIVATE_KEY="$(unescape_newlines "$LAST_APPLE_PRIVATE_KEY")"
  LAST_APPLE_BUNDLE_ID="$(grep -E '^APPLE_BUNDLE_ID=' "$STATE_FILE" | sed 's/^APPLE_BUNDLE_ID=//')"
fi

PROJECT_ID="$LAST_PROJECT_ID"
APPLE_SHARED_SECRET="$LAST_APPLE_SHARED_SECRET"
GOOGLE_PLAY_PACKAGE_NAME="$LAST_GOOGLE_PLAY_PACKAGE_NAME"
APPLE_ISSUER_ID="$LAST_APPLE_ISSUER_ID"
APPLE_KEY_ID="$LAST_APPLE_KEY_ID"
APPLE_PRIVATE_KEY="$LAST_APPLE_PRIVATE_KEY"
APPLE_BUNDLE_ID="$LAST_APPLE_BUNDLE_ID"

review_and_edit_saved_values

echo ""
if [ "$USE_SAVED_VALUES_WITHOUT_REPROMPT" != "true" ]; then
  prompt_project_id
fi

if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: Project ID cannot be empty."
  exit 1
fi

echo "🔄 Configuring project: $PROJECT_ID..."
firebase use --add "$PROJECT_ID" || firebase use "$PROJECT_ID"

echo ""
echo "🔑 Verifying Firebase session..."
firebase login

echo "📁 Preparing deployment environment in $TEMP_DIR..."
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR/functions"

# Copy our backend logic
cp "$DIR/index.js" "$TEMP_DIR/functions/easy_subs_backend.js"

# Create firebase.json in the root of the temp dir
cat << 'EOF' > "$TEMP_DIR/firebase.json"
{
  "functions": {
    "source": "functions"
  }
}
EOF

# Create a basic package.json and entry index.js in the functions folder
cat << 'EOF' > "$TEMP_DIR/functions/package.json"
{
  "name": "easy-subs-functions",
  "description": "Standalone easy_subs_firebase deployment",
  "engines": {
    "node": "20"
  },
  "main": "index.js",
  "dependencies": {
    "firebase-admin": "^12.7.0",
    "firebase-functions": "^5.1.1",
    "googleapis": "^140.0.0",
    "jsonwebtoken": "^9.0.2"
  }
}
EOF

cat << 'EOF' > "$TEMP_DIR/functions/index.js"
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const functions = require('firebase-functions/v1');
const easySubs = require('./easy_subs_backend');

const app = initializeApp();
const admin = { app, firestore: getFirestore() };
// Inject FieldValue implicitly so the wrapper can access it
admin.FieldValue = require('firebase-admin/firestore').FieldValue;

exports.easySubs = easySubs.createEasySubsFunctions(admin, functions);
EOF

echo ""
echo "🔐 Configure required env vars for full validation flow"
if [ "$USE_SAVED_VALUES_WITHOUT_REPROMPT" != "true" ]; then
  prompt_apple_shared_secret
  prompt_google_play_package_name

  echo ""
  echo "🔐 Optional (recommended): Apple Server API credentials for StoreKit2 JWS"
  prompt_apple_issuer_id
  prompt_apple_key_id
  prompt_apple_private_key
  prompt_apple_bundle_id
else
  echo "✅ Using saved values without additional prompts."
fi

validate_apple_server_api_values

# Persist values for next runs (local-only)
ESCAPED_APPLE_PRIVATE_KEY="$(escape_newlines "$APPLE_PRIVATE_KEY")"
cat > "$STATE_FILE" << EOF
PROJECT_ID=$PROJECT_ID
APPLE_SHARED_SECRET=$APPLE_SHARED_SECRET
GOOGLE_PLAY_PACKAGE_NAME=$GOOGLE_PLAY_PACKAGE_NAME
APPLE_ISSUER_ID=$APPLE_ISSUER_ID
APPLE_KEY_ID=$APPLE_KEY_ID
APPLE_PRIVATE_KEY=$ESCAPED_APPLE_PRIVATE_KEY
APPLE_BUNDLE_ID=$APPLE_BUNDLE_ID
EOF
chmod 600 "$STATE_FILE"

if [ -z "$APPLE_SHARED_SECRET" ] || [ -z "$GOOGLE_PLAY_PACKAGE_NAME" ]; then
  echo "⚠️ Missing env vars. Deployment can continue, but purchase validation will fail until both are set."
else
  ESCAPED_APPLE_PRIVATE_KEY_ENV="$(escape_newlines "$APPLE_PRIVATE_KEY")"
  cat <<EOF > "$TEMP_DIR/functions/.env"
APPLE_SHARED_SECRET=$APPLE_SHARED_SECRET
GOOGLE_PLAY_PACKAGE_NAME=$GOOGLE_PLAY_PACKAGE_NAME
APPLE_ISSUER_ID=$APPLE_ISSUER_ID
APPLE_KEY_ID=$APPLE_KEY_ID
APPLE_PRIVATE_KEY=$ESCAPED_APPLE_PRIVATE_KEY_ENV
APPLE_BUNDLE_ID=$APPLE_BUNDLE_ID
EOF
  echo "✅ Wrote $TEMP_DIR/functions/.env"
fi

echo "📦 Installing Node.js dependencies (this might take a few seconds)..."
cd "$TEMP_DIR/functions"
npm install --silent

echo "☁️ Deploying to Firebase Cloud Functions for project $PROJECT_ID..."
cd "$TEMP_DIR"
if ! firebase deploy --only "functions:easySubs" --project "$PROJECT_ID" --force; then
    echo "❌ Error during deployment."
    cd "$DIR"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Cleanup
cd "$DIR"
echo "🧹 Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

FUNCTIONS_REGION="${FUNCTIONS_REGION:-us-central1}"
APPLE_WEBHOOK_URL="https://${FUNCTIONS_REGION}-${PROJECT_ID}.cloudfunctions.net/easySubs-appleWebhook"
VERIFY_PURCHASE_CALLABLE_URL="https://${FUNCTIONS_REGION}-${PROJECT_ID}.cloudfunctions.net/easySubs-verifyPurchase"

echo ""
echo "✅==========================================================✅"
echo "🎉 Deployment completed successfully!"
echo "Your functions (verifyPurchase, appleWebhook, googlePubSubHandler)"
echo "are now in your project: $PROJECT_ID"
echo ""
echo "🔗 Integration endpoints"
echo "- Apple webhook URL: $APPLE_WEBHOOK_URL"
echo "- verifyPurchase callable URL (reference): $VERIFY_PURCHASE_CALLABLE_URL"
echo "- Google Play RTDN topic (no URL in this setup): play-billing"
echo ""
echo "📌 Configure these in their respective places:"
echo "1) App Store Connect > Your App > App Store Server Notifications > Production Server URL"
echo "   Paste: $APPLE_WEBHOOK_URL"
echo "2) Google Play Console > Monetization setup > Real-time developer notifications"
echo "   Set Cloud Pub/Sub topic: play-billing"
echo ""
echo "ℹ️ If you deploy to a different region, replace ${FUNCTIONS_REGION} in the URLs above."
echo ""
if [ -z "$APPLE_SHARED_SECRET" ] || [ -z "$GOOGLE_PLAY_PACKAGE_NAME" ]; then
  echo "⚠️  Required env vars for full validation flow:"
  echo "- APPLE_SHARED_SECRET"
  echo "- GOOGLE_PLAY_PACKAGE_NAME"
  echo ""
  echo "This script now asks for both values and writes a .env during deploy."
  echo "If you left them empty, re-run deploy.sh and provide both values."
else
  echo "✅ Required env vars were provided and written to .env for this deploy."
fi
echo "✅==========================================================✅"
echo ""