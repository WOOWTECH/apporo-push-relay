#!/usr/bin/env bash
# Apporo aiot push relay — Google Cloud Run 佈建腳本（us-west1）
#
# 這支腳本是 WOOW 的 services/woowtech-push-relay/deploy/woowtech-deploy.sh 的移植版。
# 最大的差異：**它不是一支跑到底的腳本**。
#
#   WOOW 原腳本 :55-57 的 `gcloud run deploy` 沒有 `--no-traffic`，
#   一次就把新 revision 推到 100% 流量。「無流量 candidate 先行」是 WOOW 在
#   2026-09-13 的修正部署才採用的做法。照抄那支腳本會直接跳過那道閘門。
#
# 因此這裡拆成必須逐段呼叫的 stage，每段之間由人決定要不要往下走：
#
#   ./deploy/apporo-deploy.sh infra       # 2-1 ~ 2-5 API / Firestore / TTL / SA / Artifact Registry
#   ./deploy/apporo-deploy.sh build       # 2-6   建映像，印出 image digest
#   ./deploy/apporo-deploy.sh candidate   # 2-7   部署 revision，--no-traffic --tag candidate
#   ./deploy/apporo-deploy.sh log-filter  # 2-8   排除 Cloud Run 請求日誌（含 IP / UA）
#   ./deploy/apporo-deploy.sh status      # 任何時候的讀回
#   ./deploy/apporo-deploy.sh traffic     # 2-11  切流到 100%（需 Owner 批准字句）
#
# 章節編號對應 research/apporo-aiot/us-push-loop-acceptance.md §2。
# 每一段結束後請依該文件做讀回並留存證據；本腳本只負責「做」與「印出可貼的讀回」。
#
# -----------------------------------------------------------------------------
# 這支腳本刻意不做的事
# -----------------------------------------------------------------------------
# - 不建立 aiot.apporo.ai 的 DNS 紀錄
# - 不部署 Cloudflare Worker
#   （Apporo 的 Worker 草稿在 research/apporo-aiot/cloudflare-worker-apporo.js，
#    它的 RELAY_ORIGIN 要填 `candidate` 這一段讀回的 Cloud Run status.url。
#    §2-12 明講：§2-8～2-11 全通過之前不要建 DNS、不要部署 Worker——
#    初次部署的第一個 revision 能不能真的停在 0% 流量未經確認，
#    真正有效的「無流量」閘門是**對外入口尚未接上**。)
# - 不上傳 APNs 金鑰（.p8 由 Owner 在 Firebase console 手動上傳）
# - 不做 `gcloud auth login`（互動式，由 Owner 先完成）
#
# -----------------------------------------------------------------------------
# 前置（由 Owner 完成，見 §2-0）
# -----------------------------------------------------------------------------
#   a. 建立 GCP / Firebase 專案 apporo-aiot-app（專案編號 377872140647）
#   b. 開通 Blaze 計費
#   c. 安裝 gcloud 並 `gcloud auth login`
#   d. 決定 Firestore 位置與「主要儲存」清單範圍 —— 🔴 位置建立後不可逆
set -euo pipefail

# 與 WOOW 腳本的另一個差異：這裡**不**設 CLOUDSDK_CORE_DISABLE_PROMPTS=1。
# 原腳本把確認提示一併吃掉，包含「要不要建立這個不可逆資源」那一類。
# 逐段執行時應該看得到那些提示。

PROJECT_ID="${PROJECT_ID:-apporo-aiot-app}"
REGION="${REGION:-us-west1}"          # WOOW 是 asia-east1
SERVICE="${SERVICE:-mobile-push}"     # 服務名沿用
REPO="${REPO:-mobile-push}"
SA_NAME="${SA_NAME:-mobile-push}"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
# 【未確認】500 是直接沿用 WOOW 的值，美國市場的合理值未經 Owner 確認。
# 改這個值會影響驗收文件 §3.4 的配額斷言。
MAX_NOTIFICATIONS_PER_DAY="${MAX_NOTIFICATIONS_PER_DAY:-500}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

require_clean_source() {
  # §2-6：來源完整性必須先於 build。一個未提交的工作樹沒辦法用 commit 指認。
  if ! git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null; then
    die "工作樹有未提交的修改；先 commit，否則 build 的來源無法用 commit 指認。"
  fi
}

source_integrity() {
  step "來源完整性（請整段留存，比照 WOOW 的 source_integrity 區塊）"
  note "base commit: $(git -C "$ROOT" rev-parse HEAD)"
  note "逐檔 sha256："
  for f in functions/handlers.js functions/rate-limiter/util.js \
           functions/rate-limiter/firestore-rate-limiter.js; do
    note "  $(shasum -a 256 "$ROOT/$f" 2>/dev/null || sha256sum "$ROOT/$f")"
  done
  note "🔴 build 的來源必須包含 handlers.js 的 \`req.body || {}\` 與"
  note "   \`typeof token !== 'string'\`。少了這兩行，驗收 §3 的負向案例會回 500 而不是 403。"
  note "🔴 還要附上本機測試結果（三個時區各 203/203、exit 0）。"
}

cmd_infra() {
  gcloud config set project "$PROJECT_ID" >/dev/null

  step "2-1 啟用 API"
  gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com firestore.googleapis.com fcm.googleapis.com \
    logging.googleapis.com
  note "讀回：gcloud services list --enabled （六項全在）"

  step "2-2 🔴 Firestore native，${REGION} —— 位置不可逆"
  if gcloud firestore databases describe --database='(default)' >/dev/null 2>&1; then
    note "已存在，跳過建立。"
  else
    note "官方文件：once you provision a database instance, you cannot change its location setting."
    note "${REGION} 是單一區域，不是多區域。建立後只能砍專案重來。"
    read -r -p "   確定要在 ${REGION} 建立 Firestore native 資料庫？輸入 ${REGION} 繼續：" confirm
    [ "$confirm" = "$REGION" ] || die "未確認，中止。"
    gcloud firestore databases create --location="$REGION" --type=firestore-native
  fi
  gcloud firestore databases describe --database='(default)' \
    --format='value(locationId,type)' || true
  note "讀回：type 必須是 FIRESTORE_NATIVE，不是 Datastore 模式。"

  step "2-3 Firestore TTL：配額文件在 expiresAt（UTC 日終）之後自動刪除"
  gcloud firestore fields ttls update expiresAt --collection-group=tokens --enable-ttl --quiet
  gcloud firestore fields describe expiresAt --collection-group=tokens \
    --format='value(ttlConfig.state)' || true
  note "讀回：狀態要等到 ACTIVE 才算數（剛啟用可能顯示 CREATING）。"
  note "這一行與 rate-limiter 的 UTC 日界線是同一件事的兩面。"

  step "2-4 Service account + 最小 IAM"
  if ! gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" --display-name="Apporo aiot push relay"
  fi
  for role in roles/datastore.user roles/firebasecloudmessaging.admin roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${SA}" \
      --role="$role" --condition=None --quiet >/dev/null
  done
  gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
    --filter="bindings.members:${SA}" --format='value(bindings.role)' || true
  note "讀回：必須**恰好**是上面三個角色。多出 roles/editor、roles/owner 一律視為不通過。"
  note "⚠️ 不要用 Compute Engine 預設 SA 跑 Cloud Run（權限過大）。"

  step "2-5 Artifact Registry（與 Cloud Run 同區）"
  if ! gcloud artifacts repositories describe "$REPO" --location="$REGION" >/dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$REGION"
  fi
  gcloud artifacts repositories describe "$REPO" --location="$REGION" \
    --format='value(name,format)' || true

  step "infra 完成。下一步：./deploy/apporo-deploy.sh build"
}

cmd_build() {
  require_clean_source
  source_integrity

  local tag image
  tag="$(git -C "$ROOT" rev-parse --short HEAD)"
  image="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE}:${tag}"

  step "2-6 Build ${image}"
  gcloud builds submit "$ROOT/functions" --tag "$image" --project "$PROJECT_ID"

  step "讀回 image digest（🔴 不要只記 tag——tag 可以被覆寫）"
  gcloud artifacts docker images describe "$image" --project "$PROJECT_ID" \
    --format='value(image_summary.fully_qualified_digest)'
  note "把上面那串 ...@sha256:... 傳給下一段："
  note "  IMAGE=<digest> ./deploy/apporo-deploy.sh candidate"
}

cmd_candidate() {
  : "${IMAGE:?把 build 那段讀回的 <...>@sha256:<...> 設進 IMAGE}"
  case "$IMAGE" in
    *@sha256:*) ;;
    *) die "IMAGE 必須是 digest（@sha256:...），不接受 tag；tag 會被覆寫，之後無法指認部署的到底是哪份程式。" ;;
  esac

  step "2-7 部署 revision —— 無流量 candidate 先行"
  note "🔴 初次部署沒有前一版可回滾。WOOW 的切流收據裡有 --to-revisions=<舊 revision>=100"
  note "   這條退路，Apporo 的第一次部署沒有。第一次的「回滾」只有「收回對外入口」"
  note "   與「刪掉服務」兩種，兩者都不是無痛的。"
  note "🔴【待核對】服務尚不存在時，第一個 revision 是否真的能停在 0% 流量，"
  note "   gcloud 的行為要在當下確認，不要假設。所以在 §2-8～2-11 全部通過之前，"
  note "   **不要**建立 DNS 紀錄、**不要**部署 Worker——那才是真正有效的無流量閘門。"

  gcloud run deploy "$SERVICE" \
    --image "$IMAGE" \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --service-account "$SA" \
    --allow-unauthenticated \
    --set-env-vars "MAX_NOTIFICATIONS_PER_DAY=${MAX_NOTIFICATIONS_PER_DAY}" \
    --no-traffic --tag candidate

  cmd_status
  note "⚠️ status.url 要**讀回**，不要用區域代碼猜"
  note "   （WOOW 是 ...-de.a.run.app，那是 asia-east1 的；us-west1 不一樣）。"
  note "   這個值之後要填進 research/apporo-aiot/cloudflare-worker-apporo.js 的 RELAY_ORIGIN。"
  note "下一步：./deploy/apporo-deploy.sh log-filter，然後才做 §2-9 的 health 與負向驗證"
  note "（打 Cloud Run URL，不是 aiot.apporo.ai——Worker 只代理 /api/...，/health 不會通）。"
}

cmd_log_filter() {
  step "2-8 排除這個服務的 Cloud Run 請求日誌（它們會記錄 client IP 與 User-Agent）"
  note "🔴 建議在第一次真機推播之前完成，否則第一次推播的來源 IP 會留在日誌裡。"
  local filter
  filter='resource.type="cloud_run_revision" AND resource.labels.service_name="'"$SERVICE"'" AND logName:"run.googleapis.com%2Frequests"'
  if gcloud logging sinks describe _Default --project "$PROJECT_ID" \
       --format='value(exclusions[].name)' | grep -qw "${SERVICE}-requests"; then
    note "exclusion ${SERVICE}-requests 已存在，跳過。"
  else
    gcloud logging sinks update _Default --project "$PROJECT_ID" \
      --add-exclusion="name=${SERVICE}-requests,filter=${filter}"
  fi
  gcloud logging sinks describe _Default --project "$PROJECT_ID" \
    --format='value(exclusions[].name)'
  note "額外檢查：對該 revision 抽樣讀 200 筆日誌，確認 remoteIp / userAgent /"
  note "requestBody / notification / push token 這幾類鍵都沒有出現。"
  note "抽樣結果只記「出現次數」，🔴 不要把日誌原文貼進報告。"
}

cmd_status() {
  step "讀回 Cloud Run 服務狀態"
  gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" \
    --format='yaml(status.url, status.latestCreatedRevisionName, status.traffic,
                   spec.template.spec.containers[0].image,
                   spec.template.spec.serviceAccountName,
                   spec.template.spec.containers[0].env)'
}

cmd_traffic() {
  : "${REVISION:?把要吃流量的 revision 名稱設進 REVISION（🔴 釘 revision，不要用 --to-latest）}"
  : "${APPROVED_BY:?把 Owner 的批准字句原文設進 APPROVED_BY，這句要留存進收據}"

  step "2-11 切流到 100%"
  note "revision : ${REVISION}"
  note "批准     : ${APPROVED_BY}"
  note "🔴 釘住 revision 可讓「日後任何人 deploy」不會自動把流量帶走，所以不用 --to-latest。"
  note "🔴 初次部署沒有前一版可回滾。這裡的「回滾」只有："
  note "   (a) 把 Cloudflare route／DNS 收回（對外斷路，Cloud Run 仍在跑）"
  note "   (b) gcloud run services delete（破壞性）"
  note "   第二次以後的部署才會有 --to-revisions=<舊 revision>=100 這條乾淨退路。"
  read -r -p "   §2-9（health + 負向）與 §2-10（指定測試機實體收到推播）都通過了嗎？輸入 yes 繼續：" confirm
  [ "$confirm" = "yes" ] || die "未確認，中止。"

  gcloud run services update-traffic "$SERVICE" --region "$REGION" --project "$PROJECT_ID" \
    --to-revisions="${REVISION}=100"

  cmd_status
  note "結案證據缺一不可：traffic 100%、revision 名稱、image digest（@sha256:）、建立時間、服務 URL。"
  note "最後一步（§2-12，本腳本不做）：建 DNS → 把 status.url 填進 Worker 的 RELAY_ORIGIN →"
  note "部署 Worker + 掛 route → 重跑 §3 負向案例打 https://aiot.apporo.ai/api/... 並比對結果一致。"
}

usage() {
  sed -n '2,40p' "$0"
  exit 1
}

case "${1:-}" in
  infra)       cmd_infra ;;
  build)       cmd_build ;;
  candidate)   cmd_candidate ;;
  log-filter)  cmd_log_filter ;;
  status)      cmd_status ;;
  traffic)     cmd_traffic ;;
  *)           usage ;;
esac
