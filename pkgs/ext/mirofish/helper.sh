#!/usr/bin/env bash
set -Eeuo pipefail

patch_vite_config() {
  local source_dir="$1"
  local config_file="${source_dir}/frontend/vite.config.js"

  perl -0pi -e 's/server: \{/server: {\n      allowedHosts: (process.env.__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS || "").split(",").map(host => host.trim()).filter(Boolean),/' "${config_file}"
  substituteInPlace "${config_file}" \
    --replace-fail "open: true," "open: false,"
  perl -0pi -e 's/\n  }\n\}\)/\n  },\n  preview: {\n    port: 3000,\n    allowedHosts: (process.env.__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS || "").split(",").map(host => host.trim()).filter(Boolean)\n  }\n})/' "${config_file}"
}

patch_frontend_defaults() {
  local source_dir="$1"
  local i18n_file="${source_dir}/frontend/src/i18n/index.js"
  local api_file="${source_dir}/frontend/src/api/index.js"
  local index_file="${source_dir}/frontend/index.html"

  perl -0pi -e 's/const savedLocale = localStorage\.getItem\(\x27locale\x27\) \|\| \x27zh\x27/const defaultLocale = import.meta.env.VITE_DEFAULT_LOCALE || \x27en\x27\nconst savedLocale = localStorage.getItem(\x27locale\x27) || defaultLocale/' "${i18n_file}"
  substituteInPlace "${i18n_file}" \
    --replace-fail "fallbackLocale: 'zh'," "fallbackLocale: defaultLocale,"
  substituteInPlace "${api_file}" \
    --replace-fail "timeout: 300000, // 5分钟超时（本体生成可能需要较长时间）" "timeout: Number(import.meta.env.VITE_API_TIMEOUT_MS || 900000), // Long-running local LLM calls"

  substituteInPlace "${index_file}" \
    --replace-fail '<html lang="zh">' '<html lang="en">' \
    --replace-fail "localStorage.getItem('locale') || 'zh'" "localStorage.getItem('locale') || 'en'" \
    --replace-fail 'content="MiroFish - 社交媒体舆论模拟系统"' 'content="MiroFish - social media opinion simulation system"' \
    --replace-fail '<title>MiroFish - 预测万物</title>' '<title>MiroFish - Predict Everything</title>'
}

patch_reasoning_effort() {
  local source_dir="$1"

  perl -0pi -e 's/(    LLM_MODEL_NAME = os\.environ\.get\(\x27LLM_MODEL_NAME\x27, \x27gpt-4o-mini\x27\)\n)/$1    LLM_REASONING_EFFORT = os.environ.get(\x27LLM_REASONING_EFFORT\x27)\n/' "${source_dir}/backend/app/config.py"

  perl -0pi -e 's/(        if response_format:\n            kwargs\["response_format"\] = response_format\n)/$1\n        if Config.LLM_REASONING_EFFORT:\n            kwargs["reasoning_effort"] = Config.LLM_REASONING_EFFORT\n/' "${source_dir}/backend/app/utils/llm_client.py"

  perl -0pi -e 's/model=self\.model_name,\n                    messages=/model=self.model_name,\n                    **({"reasoning_effort": Config.LLM_REASONING_EFFORT} if Config.LLM_REASONING_EFFORT else {}),\n                    messages=/g' "${source_dir}/backend/app/services/simulation_config_generator.py"

  perl -0pi -e 's/model=self\.model_name,\n                    messages=/model=self.model_name,\n                    **({"reasoning_effort": Config.LLM_REASONING_EFFORT} if Config.LLM_REASONING_EFFORT else {}),\n                    messages=/g' "${source_dir}/backend/app/services/oasis_profile_generator.py"
}

patch_local_graph_runtime() {
  local source_dir="$1"
  local config_file="${source_dir}/backend/app/config.py"
  local project_file="${source_dir}/backend/app/models/project.py"
  local graph_builder_file="${source_dir}/backend/app/services/graph_builder.py"
  local graph_api_file="${source_dir}/backend/app/api/graph.py"

  substituteInPlace "${config_file}" \
    --replace-fail "DEFAULT_CHUNK_SIZE = 500  # 默认切块大小" "DEFAULT_CHUNK_SIZE = int(os.environ.get('MIROFISH_DEFAULT_CHUNK_SIZE', '500'))  # Default chunk size" \
    --replace-fail "DEFAULT_CHUNK_OVERLAP = 50  # 默认重叠大小" "DEFAULT_CHUNK_OVERLAP = int(os.environ.get('MIROFISH_DEFAULT_CHUNK_OVERLAP', '50'))  # Default chunk overlap"

  substituteInPlace "${project_file}" \
    --replace-fail "chunk_size: int = 500" "chunk_size: int = field(default_factory=lambda: Config.DEFAULT_CHUNK_SIZE)" \
    --replace-fail "chunk_overlap: int = 50" "chunk_overlap: int = field(default_factory=lambda: Config.DEFAULT_CHUNK_OVERLAP)" \
    --replace-fail "chunk_size=data.get('chunk_size', 500)," "chunk_size=data.get('chunk_size', Config.DEFAULT_CHUNK_SIZE)," \
    --replace-fail "chunk_overlap=data.get('chunk_overlap', 50)," "chunk_overlap=data.get('chunk_overlap', Config.DEFAULT_CHUNK_OVERLAP),"

  perl -0pi -e 's/(        start_time = time\.time\(\)\n        pending_episodes = set\(episode_uuids\)\n)/        timeout = int(os.environ.get(\x27MIROFISH_EPISODE_WAIT_TIMEOUT_SECONDS\x27, timeout))\n$1/' "${graph_builder_file}"

  perl -0pi -e 's/                break\n            \n            # 检查每个 episode 的处理状态/                raise TimeoutError(\n                    f"Timed out waiting for Zep episodes: {completed_count}\/{total_episodes} completed after {timeout}s"\n                )\n            \n            # 检查每个 episode 的处理状态/' "${graph_builder_file}"

  perl -0pi -e 's/                except Exception as e:\n                    # 忽略单个查询错误，继续\n                    pass/                except Exception as e:\n                    error_text = str(e)\n                    if " failed:" in error_text or "failed:" in error_text:\n                        raise RuntimeError(error_text)\n                    # Transient status lookup errors should not fail the whole build.\n                    continue/' "${graph_builder_file}"

  substituteInPlace "${graph_api_file}" \
    --replace-fail '"data": [t.to_dict() for t in tasks],' '"data": tasks,'
}

main() {
  if [[ $# -ne 1 ]]; then
    echo "usage: $0 SOURCE_DIR" >&2
    return 2
  fi

  local source_dir="$1"

  patch_vite_config "${source_dir}"
  patch_frontend_defaults "${source_dir}"
  patch_reasoning_effort "${source_dir}"
  patch_local_graph_runtime "${source_dir}"
}

main "$@"
