#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

source env_vars
source "$(dirname "$0")"/common.sh

# 1. get & save kubeconfig for the installed ARO-HCP cluster

rp_post_request "${CLUSTER_RESOURCE_ID}/requestadmincredential"
mv ./kubeconfig ~/.kube/${CLUSTER_NAME}.kubeconfig
KUBECONFIG=~/.kube/${CLUSTER_NAME}.kubeconfig

# 2. create service principal & external auth.

SPNAME="${CLUSTER_NAME}-sp-arohcp"
SP=$(az ad sp list --display-name ${SPNAME} | jq -r first)
if [ "$SP" == "null" ]; then
	SP=$(az ad sp create-for-rbac \
		--name ${SPNAME} \
		--role "Custom-Owner (Block Billing and Subscription deletion)" \
		--scopes "/subscriptions/${SUBSCRIPTION_ID}")
fi

APP_ID=$(echo "$SP" | jq -r .appId)
AUD="[\"$APP_ID\"]"

EXT_AUTH_FILE="external_auth.json"
EXT_AUTH_TMPL_FILE="external_auth.tmpl.json"

jq \
	--arg url "https://login.microsoftonline.com/${TENANT_ID}/v2.0"\
	--arg cid "$APP_ID" \
	--argjson aud "$AUD" \
	'.properties.issuer.url = $url | .properties.issuer.audiences = $aud | .properties.clients[0].clientId = $cid' \
	"$EXT_AUTH_TMPL_FILE" > ${EXT_AUTH_FILE}

rp_put_request "${CLUSTER_RESOURCE_ID}/externalAuths/entra" "@${EXT_AUTH_FILE}"

CONSOLE_URL=$(rp_get_request ${CLUSTER_RESOURCE_ID} | jq -r .properties.console.url)
OAUTH_URL=$(echo $CONSOLE_URL | sed 's!console-openshift-console!oauth-openshift!')

az ad app update \
	--id "$APP_ID" \
	--web-redirect-uris \
	"$OAUTH_URL/oauth2callback/AAD" \
	"$CONSOLE_URL/auth/callback"

az ad app update \
	--id "$APP_ID" \
	--enable-id-token-issuance true

az ad app update \
	--id "$APP_ID" \
	--optional-claims '{"idToken":[{"name":"groups","essential":false}]}'

az ad app update \
	--id "$APP_ID" \
	--set groupMembershipClaims=SecurityGroup

az ad app permission add \
	--id "$APP_ID" \
	--api 00000003-0000-0000-c000-000000000000 \
	--api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope

APP_SECRET=$(az ad app credential reset \
	--id $APP_ID \
	--append | jq -r .password)

kubectl --kubeconfig $KUBECONFIG \
	--namespace openshift-config \
	 create secret generic entra-console-openshift-console \
	--from-literal=clientID="$APP_ID" \
	--from-literal=clientSecret="$APP_SECRET" \
	--from-literal=issuer="https://login.microsoftonline.com/$TENANT_ID/v2.0" \
	--from-literal=extraScopes="openid,profile"

export USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

kubectl --kubeconfig="$KUBECONFIG" \
	create clusterrolebinding aad-admin \
	--clusterrole=cluster-admin \
	--user="${USER_OBJECT_ID}"

export GROUP_OBJECT_ID=$(az ad group show --group "aro-hcp-engineering-App Developer" --query id -o tsv)

kubectl --kubeconfig="$KUBECONFIG" \
	create clusterrolebinding aad-admins-group \
	--clusterrole=cluster-admin \
	--group="${GROUP_OBJECT_ID}"
