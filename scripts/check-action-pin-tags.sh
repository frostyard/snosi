#!/usr/bin/env bash
# Online check of the action pins in .github/workflows and .github/actions (ADR-0088, ADR-0090):
#   OWNER/REPO[/PATH]@SHA # vX.Y[.Z]           tag vX.Y[.Z] (X.Y[.Z] if it is missing) names SHA
#   OWNER/REPO[/PATH]@SHA # BRANCH YYYY-MM-DD  SHA is on BRANCH (compare: identical or behind)
#   frostyard/core/.github/workflows/F@SHA     SHA is on core's main
# It prints every other pin, and every uses: key on a line it cannot read, as skipped.
# Needs bash 4, git and an authenticated gh.
set -euo pipefail
status=0 checked=0 skipped=0
declare -A seen
# 1 line `[- ]uses: VALUE [# COMMENT]`; the key may be quoted, the value may be quoted.
pin='^[[:space:]]*(-[[:space:]]+)?(uses|"uses"|'\''uses'\'')[[:space:]]*:[[:space:]]+([^][:space:]#|>{}&*!"'\''[][^[:space:]]*|"[^"]*"|'\''[^'\'']*'\'')([[:space:]]+#[[:space:]]*(.*))?$'
while IFS= read -r hit; do
	file=${hit%%:*} rest=${hit#*:}
	line=${rest%%:*} text=${rest#*:}
	text=${text%$'\r'}
	text=${text#$'\xef\xbb\xbf'}
	[[ $text =~ ^[[:space:]]*# ]] && continue
	if [[ ! $text =~ $pin ]]; then
		echo "skipped: $file:$line: a uses: key this script cannot read (flow mapping, block scalar, text)"
		skipped=$((skipped + 1))
		continue
	fi
	ref=${BASH_REMATCH[3]} comment=${BASH_REMATCH[5]}
	ref=${ref#[\"\']} && ref=${ref%[\"\']}
	comment=${comment%"${comment##*[![:space:]]}"}
	[[ $ref == ./* || -n ${seen["$ref # $comment"]:-} ]] && continue
	seen["$ref # $comment"]=1
	tag='' branch='' why=''
	if [[ ! $ref =~ ^[^./][^@]*/[^@]+@[0-9a-f]{40}$ ]]; then
		why="not OWNER/REPO[/PATH]@SHA"
	elif [[ $comment =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
		tag=$comment
	elif [[ $ref == frostyard/core/.github/workflows/* ]]; then
		branch=main
	elif [[ $comment =~ ^([A-Za-z0-9._/-]+)\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		branch=${BASH_REMATCH[1]}
	else
		why="the comment names no vX.Y[.Z] tag and no BRANCH YYYY-MM-DD"
	fi
	if [[ -n $why ]]; then
		echo "skipped: $ref # $comment ($why)"
		skipped=$((skipped + 1))
		continue
	fi
	checked=$((checked + 1))
	repo=$(cut -d/ -f1-2 <<<"${ref%@*}")
	sha=${ref##*@}
	if [[ -n $tag ]]; then
		for t in "$tag" "${tag#v}"; do
			got=$(git ls-remote "https://github.com/$repo" "refs/tags/$t" "refs/tags/$t^{}" | awk 'END { print $1 }')
			[[ -n $got ]] && break
		done
		[[ $got == "$sha" ]] || { echo "$ref: tag $tag is ${got:-missing} upstream" >&2; status=1; }
	else
		got=$(gh api "repos/$repo/compare/$branch...$sha" --jq .status 2>/dev/null) || got="no comparison"
		[[ $got == identical || $got == behind ]] || { echo "$ref: not on $branch upstream ($got)" >&2; status=1; }
	fi
done < <(grep -rnsE '(^|[[:space:]{,[])["'\'']?uses["'\'']?[[:space:]]*:' .github/workflows .github/actions)
echo "checked $checked pins, skipped $skipped"
exit "$status"
