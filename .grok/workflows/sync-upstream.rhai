let meta = #{
    name: "sync-upstream",
    description: "安全地将 GitHub 上游 merge 到当前分支，分层保护本地配置（.grok/、根目录 custom、AGENTS 等），不 push",
    phases: [
        #{ title: "Inspect", detail: "git 状态、进行中操作、阻塞性脏检查、remote" },
        #{ title: "Fetch", detail: "确认 upstream remote 并 fetch" },
        #{ title: "Protect", detail: "备份分支 + 分层保护清单 + 指纹" },
        #{ title: "Merge", detail: "默认 merge；保护路径本地优先" },
        #{ title: "Verify", detail: "干净状态、指纹、变更/复活摘要、可选 lint" },
    ],
    when_to_use: "在本 Rime 仓从 iDvel/origin 拉上游且要保留本地 .grok/ 与 custom 配置时使用 /sync-upstream",
};

// --- output schemas ---
let inspect_schema = #{
    "type": "object",
    "required": [
        "clean",
        "blocking_dirty",
        "in_progress",
        "in_progress_kind",
        "current_branch",
        "head_sha",
        "remotes_summary",
        "upstream_remote",
        "upstream_url",
        "default_branch",
        "dirty_summary",
        "ignored_untracked_summary",
        "notes",
    ],
    "properties": #{
        "clean": #{ "type": "boolean" },
        "blocking_dirty": #{ "type": "boolean" },
        "in_progress": #{ "type": "boolean" },
        "in_progress_kind": #{ "type": "string" },
        "current_branch": #{ "type": "string" },
        "head_sha": #{ "type": "string" },
        "remotes_summary": #{ "type": "string" },
        "upstream_remote": #{ "type": "string" },
        "upstream_url": #{ "type": "string" },
        "default_branch": #{ "type": "string" },
        "dirty_summary": #{ "type": "string" },
        "ignored_untracked_summary": #{ "type": "string" },
        "notes": #{ "type": "string" },
    },
};

let fetch_schema = #{
    "type": "object",
    "required": ["ok", "upstream_remote", "fetched_ref", "preview_stat", "message"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "upstream_remote": #{ "type": "string" },
        "fetched_ref": #{ "type": "string" },
        "preview_stat": #{ "type": "string" },
        "message": #{ "type": "string" },
    },
};

let protect_schema = #{
    "type": "object",
    "required": ["ok", "backup_branch", "protected_paths", "fingerprint_file", "message"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "backup_branch": #{ "type": "string" },
        "protected_paths": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
        "fingerprint_file": #{ "type": "string" },
        "message": #{ "type": "string" },
    },
};

let merge_schema = #{
    "type": "object",
    "required": ["ok", "strategy_used", "conflict_files", "resolved_local", "remaining_conflicts", "message"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "strategy_used": #{ "type": "string" },
        "conflict_files": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
        "resolved_local": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
        "remaining_conflicts": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
        "message": #{ "type": "string" },
    },
};

let verify_schema = #{
    "type": "object",
    "required": [
        "ok",
        "clean",
        "protected_ok",
        "protected_failures",
        "resurrected_paths",
        "diff_stat",
        "lint_ran",
        "lint_ok",
        "rollback_hint",
        "summary",
    ],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "clean": #{ "type": "boolean" },
        "protected_ok": #{ "type": "boolean" },
        "protected_failures": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
        "resurrected_paths": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
        "diff_stat": #{ "type": "string" },
        "lint_ran": #{ "type": "boolean" },
        "lint_ok": #{ "type": "boolean" },
        "rollback_hint": #{ "type": "string" },
        "summary": #{ "type": "string" },
    },
};

// --- args（先判断 unit，再读字段）---
let branch_arg = ();
let protect_extra = ();
let strategy = "merge";
let run_lint = false;
let dry_run = false;
let allow_untracked = false;
let i_understand_rebase = false;
let upstream_remote_arg = ();
let upstream_url_arg = ();

if args != () {
    if args.branch != () && args.branch != "" {
        branch_arg = args.branch;
    }
    if args.protect != () {
        protect_extra = args.protect;
    }
    if args.strategy != () && args.strategy != "" {
        strategy = args.strategy;
    }
    if args.run_lint == true {
        run_lint = true;
    }
    if args.dry_run == true {
        dry_run = true;
    }
    if args.allow_untracked == true {
        allow_untracked = true;
    }
    if args.i_understand_rebase == true {
        i_understand_rebase = true;
    }
    if args.upstream_remote != () && args.upstream_remote != "" {
        upstream_remote_arg = args.upstream_remote;
    }
    if args.upstream_url != () && args.upstream_url != "" {
        upstream_url_arg = args.upstream_url;
    }
}

if strategy != "merge" && strategy != "rebase" {
    pause("verification", "args.strategy 只能是 \"merge\"（默认）或 \"rebase\"。");
}

if strategy == "rebase" && i_understand_rebase != true {
    pause(
        "verification",
        "已请求 strategy=rebase，但未设置 args.i_understand_rebase=true。\n\n" +
            "rebase 时 ours/theirs 与 merge 相反，极易误伤本地配置。\n" +
            "建议改用 strategy=merge；若坚持 rebase，请传入 i_understand_rebase=true 后重跑。",
    );
}

let protect_json = "[]";
if protect_extra != () {
    protect_json = json_encode(protect_extra);
}

let branch_json = "null";
if branch_arg != () {
    branch_json = json_encode(branch_arg);
}

let upstream_remote_json = "null";
if upstream_remote_arg != () {
    upstream_remote_json = json_encode(upstream_remote_arg);
}

let upstream_url_json = "null";
if upstream_url_arg != () {
    upstream_url_json = json_encode(upstream_url_arg);
}

// =============================================================================
// Phase: Inspect
// =============================================================================
phase("Inspect");

let inspect_prompt = "";
inspect_prompt += "你在对本机 git 仓库做「安全上游同步」前的只读体检。\n";
inspect_prompt += "只用 run_terminal_command 跑 git/shell。不要改文件、不要 push、不要 reset --hard、不要删除文件。\n\n";
inspect_prompt += "参数 JSON：\n";
inspect_prompt += "- branch: ";
inspect_prompt += branch_json;
inspect_prompt += "\n- upstream_remote: ";
inspect_prompt += upstream_remote_json;
inspect_prompt += "\n- upstream_url: ";
inspect_prompt += upstream_url_json;
inspect_prompt += "\n- allow_untracked: ";
inspect_prompt += allow_untracked.to_string();
inspect_prompt += "\n\n本项目提示（雾凇/rime-ice 用户目录）：\n";
inspect_prompt += "- 若 origin URL 含 iDvel/rime-ice，则上游 remote 优先为 origin。\n";
inspect_prompt += "- 若存在 mine remote，视为个人 fork，禁止 push 到 origin。\n";
inspect_prompt += "- 默认分支优先 main。\n\n";
inspect_prompt += "必须执行的步骤：\n";
inspect_prompt += "1. git rev-parse --is-inside-work-tree\n";
inspect_prompt += "2. 检测进行中操作：\n";
inspect_prompt += "   test -f .git/MERGE_HEAD; test -d .git/rebase-merge; test -d .git/rebase-apply; test -f .git/CHERRY_PICK_HEAD\n";
inspect_prompt += "   若任一为真：in_progress=true，in_progress_kind 填 merge|rebase|cherry-pick；否则 in_progress=false，in_progress_kind=\"\"。\n";
inspect_prompt += "3. git status --porcelain=v1 与 git status -sb\n";
inspect_prompt += "4. git branch --show-current; git rev-parse --short HEAD; git rev-parse HEAD\n";
inspect_prompt += "5. git remote -v\n";
inspect_prompt += "6. 选择 upstream_remote：\n";
inspect_prompt += "   - 参数指定且存在 → 用参数\n";
inspect_prompt += "   - 否则存在名为 upstream 的 remote → upstream\n";
inspect_prompt += "   - 否则 origin URL 像上游公共仓（如 iDvel/rime-ice）→ origin\n";
inspect_prompt += "   - 否则同时有 origin 与其它 remote 且 origin 像公共仓 → origin\n";
inspect_prompt += "   - 否则仅 origin → origin\n";
inspect_prompt += "   - 否则 upstream_remote=\"\" 并在 notes 说明\n";
inspect_prompt += "7. upstream_url：该 remote 的 fetch URL，没有则 \"\"\n";
inspect_prompt += "8. default_branch：参数 branch 优先；否则 main；否则 master\n";
inspect_prompt += "9. 【阻塞性脏判定 — 关键】\n";
inspect_prompt += "   porcelain 每一行：\n";
inspect_prompt += "   - 以 ?? 开头的 untracked：\n";
inspect_prompt += "     * 若路径属于默认可忽略前缀，记入 ignored_untracked_summary，不阻塞：\n";
inspect_prompt += "       .grok/  backups/  build/  sync/  任意 *.userdb/ 或 *.userdb\n";
inspect_prompt += "     * 其它 untracked：若 allow_untracked=false 则算阻塞；若 true 则仅记入 dirty_summary 不阻塞\n";
inspect_prompt += "   - 其它行（已跟踪的修改/删除/暂存/重命名等）一律阻塞\n";
inspect_prompt += "   blocking_dirty=true 当且仅当存在阻塞项。\n";
inspect_prompt += "   clean=true 当且仅当 blocking_dirty=false（允许存在被忽略的 untracked）。\n";
inspect_prompt += "   dirty_summary：列出所有阻塞项（可截断但需有代表性）；无阻塞则为 \"\"。\n";
inspect_prompt += "10. notes：ahead/behind 或 tracking 简述。\n\n";
inspect_prompt += "只返回 schema 字段，且每项必须来自真实命令输出。\n";

let inspect_r = agent(inspect_prompt, #{
    label: "inspect-git",
    capability_mode: "execute",
    output_schema: inspect_schema,
});

if inspect_r == () || !inspect_r.success || inspect_r.output == () {
    complete(#{
        success: false,
        phase: "Inspect",
        error: "Inspect 阶段失败，未做任何 git 写入。",
        rollback_hint: "尚未创建备份分支。",
    });
}

let inspect = inspect_r.output;
log("Inspect: branch=" + inspect.current_branch + " sha=" + inspect.head_sha + " clean=" + inspect.clean.to_string() + " in_progress=" + inspect.in_progress.to_string());

if inspect.in_progress == true {
    let kind = inspect.in_progress_kind;
    if kind == () {
        kind = "merge/rebase";
    }
    complete(#{
        success: false,
        phase: "Inspect",
        error: "检测到进行中的 git 操作（" + kind + "），已中止同步以免叠状态。",
        rollback_hint: "先结束或中止：git merge --abort 或 git rebase --abort 或 git cherry-pick --abort，确认 git status 干净后重跑 /sync-upstream。",
        in_progress_kind: kind,
    });
}

// 阻塞性脏：等待用户处理后重检
if inspect.clean != true || inspect.blocking_dirty == true {
    let dirty_msg = "";
    dirty_msg += "工作区存在【阻塞性】未提交变更，已拒绝同步以保护本地工作。\n\n";
    dirty_msg += "阻塞项摘要：\n";
    dirty_msg += inspect.dirty_summary;
    dirty_msg += "\n\n已忽略的 untracked（不阻塞）：\n";
    dirty_msg += inspect.ignored_untracked_summary;
    dirty_msg += "\n\n请 commit / stash / 妥善丢弃后，在 /workflows 中 resume 本运行。\n";
    dirty_msg += "不要对用户数据执行 git clean -fdx。\n";
    await_user("user", dirty_msg);

    let re_prompt = inspect_prompt;
    re_prompt += "\n注意：用户声称已清理工作区。请从头重新执行全部检查命令，不要沿用记忆。\n";
    let re_r = agent(re_prompt, #{
        label: "re-inspect-git",
        capability_mode: "execute",
        output_schema: inspect_schema,
    });
    if re_r == () || !re_r.success || re_r.output == () {
        complete(#{
            success: false,
            phase: "Inspect",
            error: "清理后重检失败。",
            rollback_hint: "尚未创建备份分支。",
        });
    }
    inspect = re_r.output;
    if inspect.in_progress == true {
        complete(#{
            success: false,
            phase: "Inspect",
            error: "重检仍检测到进行中的 merge/rebase。",
            rollback_hint: "git merge --abort 或 git rebase --abort 后重跑。",
        });
    }
    if inspect.clean != true || inspect.blocking_dirty == true {
        complete(#{
            success: false,
            phase: "Inspect",
            error: "resume 后工作区仍有阻塞性变更。",
            dirty_summary: inspect.dirty_summary,
            rollback_hint: "尚未创建备份分支。请清理后重新运行 /sync-upstream。",
        });
    }
}

if inspect.upstream_remote == () || inspect.upstream_remote == "" {
    if upstream_url_arg == () {
        pause(
            "verification",
            "未找到上游 remote。请传入 args.upstream_url（及可选 args.upstream_remote）后重新运行。",
        );
    }
}

// =============================================================================
// Phase: Fetch
// =============================================================================
phase("Fetch");

let fetch_prompt = "";
fetch_prompt += "你在为安全本地同步准备 remote 并 fetch。\n";
fetch_prompt += "用 run_terminal_command。禁止 merge/rebase/push/reset --hard/删除文件。\n\n";
fetch_prompt += "Inspect 上下文：\n";
fetch_prompt += "- current_branch: ";
fetch_prompt += json_encode(inspect.current_branch);
fetch_prompt += "\n- upstream_remote: ";
fetch_prompt += json_encode(inspect.upstream_remote);
fetch_prompt += "\n- upstream_url: ";
fetch_prompt += json_encode(inspect.upstream_url);
fetch_prompt += "\n- default_branch: ";
fetch_prompt += json_encode(inspect.default_branch);
fetch_prompt += "\n- args.upstream_url: ";
fetch_prompt += upstream_url_json;
fetch_prompt += "\n- args.upstream_remote: ";
fetch_prompt += upstream_remote_json;
fetch_prompt += "\n- args.branch: ";
fetch_prompt += branch_json;
fetch_prompt += "\n\n本项目：origin 常为 iDvel/rime-ice；mine 为个人 fork。\n\n";
fetch_prompt += "必须步骤：\n";
fetch_prompt += "1. git remote -v\n";
fetch_prompt += "2. 选定 remote 名：参数 > inspect.upstream_remote > upstream > origin\n";
fetch_prompt += "3. 若不存在：有 upstream_url 则 git remote add；否则 ok=false\n";
fetch_prompt += "4. git fetch <remote> --prune\n";
fetch_prompt += "5. 解析分支：args.branch > default_branch > main > master；git rev-parse --verify <remote>/<branch>\n";
fetch_prompt += "6. fetched_ref='<remote>/<branch>'；ok=true 仅当 fetch 成功且 ref 存在\n";
fetch_prompt += "7. preview_stat：运行 git log --oneline HEAD..<fetched_ref> | head -20 与 git diff --stat HEAD...<fetched_ref> | tail -30，把摘要写入 preview_stat（可截断）\n";
fetch_prompt += "8. message：简短中文说明\n";
fetch_prompt += "只返回 schema 字段。\n";

let fetch_r = agent(fetch_prompt, #{
    label: "fetch-upstream",
    capability_mode: "execute",
    output_schema: fetch_schema,
});

if fetch_r == () || !fetch_r.success || fetch_r.output == () {
    complete(#{
        success: false,
        phase: "Fetch",
        error: "Fetch 阶段失败，未尝试 merge。",
        rollback_hint: "尚未创建备份分支，修复 remote 后可重跑。",
    });
}

let fetch_out = fetch_r.output;
log("Fetch: ok=" + fetch_out.ok.to_string() + " ref=" + fetch_out.fetched_ref);

if fetch_out.ok != true {
    complete(#{
        success: false,
        phase: "Fetch",
        error: fetch_out.message,
        rollback_hint: "尚未创建备份分支。请检查 remote/branch 参数后重跑。",
    });
}

// dry_run：只预览，不 merge
if dry_run == true {
    let dry_report = "";
    dry_report += "# sync-upstream 预览（dry_run）\n\n";
    dry_report += "未执行 merge，未创建备份分支。\n\n";
    dry_report += "- 当前分支: ";
    dry_report += inspect.current_branch;
    dry_report += "\n- HEAD: ";
    dry_report += inspect.head_sha;
    dry_report += "\n- 将合并: ";
    dry_report += fetch_out.fetched_ref;
    dry_report += "\n- strategy: ";
    dry_report += strategy;
    dry_report += "\n\n## 预览\n\n";
    dry_report += fetch_out.preview_stat;
    dry_report += "\n\n去掉 dry_run 后重新运行即可真正同步。\n";
    let dry_path = write_scratch_file("sync-upstream-report.md", dry_report);
    complete(#{
        success: true,
        dry_run: true,
        path: dry_path,
        report: dry_report,
        upstream_ref: fetch_out.fetched_ref,
        summary: "dry_run 完成，未 merge",
    });
}

// =============================================================================
// Phase: Protect
// =============================================================================
phase("Protect");

let protect_prompt = "";
protect_prompt += "你在 merge 前创建备份分支并记录受保护路径指纹。\n";
protect_prompt += "可用 run_terminal_command。禁止 merge/rebase/push。禁止删除用户文件。\n";
protect_prompt += "可以：git branch 新建备份；在 .grok/ 下写指纹文件（无 .grok 则用 /tmp）。\n\n";
protect_prompt += "上下文：\n";
protect_prompt += "- head_sha: ";
protect_prompt += json_encode(inspect.head_sha);
protect_prompt += "\n- current_branch: ";
protect_prompt += json_encode(inspect.current_branch);
protect_prompt += "\n- args.protect 额外路径 JSON: ";
protect_prompt += protect_json;
protect_prompt += "\n\n【分层保护清单 — 只收录工作区中真实存在的路径】\n";
protect_prompt += "A 绝对本地：\n";
protect_prompt += "  - .grok/（目录）\n";
protect_prompt += "  - backups/、sync/\n";
protect_prompt += "  - 任意 *.userdb 目录\n";
protect_prompt += "  - 仓库根目录下的 *.custom.yaml（仅根目录！不要递归 others/）\n";
protect_prompt += "  - installation.yaml、user.yaml（若存在）\n";
protect_prompt += "  - 仓库根目录匹配 *.local.* 的文件\n";
protect_prompt += "B 高敏跟踪文件（存在则纳入）：\n";
protect_prompt += "  - AGENTS.md、CLAUDE.md、Claude.md、custom_phrase.txt\n";
protect_prompt += "C 不要保护（即使叫 custom）：\n";
protect_prompt += "  - others/ 下任何路径（含 patch_examples、iRime、Hamster 示例）\n";
protect_prompt += "  - cn_dicts/、en_dicts/、lua/、opencc/、*.schema.yaml 主体等\n";
protect_prompt += "D args.protect 中的每一项（存在则加入，即使用户写了 others 下路径也尊重用户）\n\n";
protect_prompt += "必须步骤：\n";
protect_prompt += "1. 组装 protected_paths：去重、排序；排除默认扫描到的 others/**（除非来自 args.protect）。\n";
protect_prompt += "2. 备份分支：backup/pre-sync-<short_sha>（HEAD 前 7 位）；已存在则 -2、-3…；git branch <名>；禁止删除旧备份。\n";
protect_prompt += "3. 指纹文件 .grok/sync-upstream-fingerprint.txt（或 /tmp/…）：每行 path 与内容 sha256；目录则对内部常规文件稳定排序后汇总哈希。\n";
protect_prompt += "4. ok=true 仅当备份分支存在且指纹文件已写。message 用中文。\n";
protect_prompt += "禁止覆盖受保护路径内容。只返回 schema。\n";

let protect_r = agent(protect_prompt, #{
    label: "protect-local",
    capability_mode: "execute",
    output_schema: protect_schema,
});

if protect_r == () || !protect_r.success || protect_r.output == () {
    complete(#{
        success: false,
        phase: "Protect",
        error: "Protect 阶段失败，未开始 merge。",
        rollback_hint: "若已部分创建备份，可执行：git branch | grep backup/pre-sync",
    });
}

let protect_out = protect_r.output;
log("Protect: ok=" + protect_out.ok.to_string() + " backup=" + protect_out.backup_branch);

if protect_out.ok != true {
    complete(#{
        success: false,
        phase: "Protect",
        error: protect_out.message,
        rollback_hint: "未开始 merge。检查：git branch | grep backup/pre-sync",
    });
}

// Rhai 侧过滤：去掉默认保护误收入的 others/ 路径（args.protect 显式项通过 "\tuser" 无法区分，
// 因此仅当路径以 others/ 开头且不在 protect_extra 明文列表时剔除。简化：剔除 others/ 除非整个 protected 项等于用户列表中的某项。）
let raw_paths = protect_out.protected_paths;
let filtered_paths = [];
if raw_paths != () {
    for p in raw_paths {
        let keep = true;
        // 以 others/ 开头则默认丢弃
        if type_of(p) == "string" {
            if p.len() >= 7 {
                let prefix = p.sub_string(0, 7);
                if prefix == "others/" {
                    keep = false;
                    // 若用户 args.protect 显式包含该路径则保留
                    if protect_extra != () {
                        for u in protect_extra {
                            if u == p {
                                keep = true;
                            }
                        }
                    }
                }
            }
        }
        if keep {
            filtered_paths.push(p);
        }
    }
}
if raw_paths != () && filtered_paths.len() < raw_paths.len() {
    let dropped = raw_paths.len() - filtered_paths.len();
    log("Protect: 已过滤 others/ 下误保护路径 " + dropped.to_string() + " 个");
}

let protected_paths_json = json_encode(filtered_paths);
let backup_branch = protect_out.backup_branch;
let fingerprint_file = protect_out.fingerprint_file;

// =============================================================================
// Phase: Merge
// =============================================================================
phase("Merge");

let merge_prompt = "";
merge_prompt += "你在把上游合并进当前分支，并对受保护配置【本地优先】。\n";
merge_prompt += "禁止 push / force-push / reset --hard / git clean -fdx / 删除保护路径 / 删除备份分支。\n\n";
merge_prompt += "上下文：\n";
merge_prompt += "- strategy: ";
merge_prompt += json_encode(strategy);
merge_prompt += "\n- fetched_ref: ";
merge_prompt += json_encode(fetch_out.fetched_ref);
merge_prompt += "\n- backup_branch: ";
merge_prompt += json_encode(backup_branch);
merge_prompt += "\n- protected_paths JSON（仅这些 + 其子路径算保护）: ";
merge_prompt += protected_paths_json;
merge_prompt += "\n\n必须步骤：\n";
merge_prompt += "1. 再次 git status --porcelain：仅允许被忽略类 untracked；若有已跟踪改动则 ok=false 停止。\n";
merge_prompt += "2. strategy=merge（推荐）：git merge --no-edit ";
merge_prompt += fetch_out.fetched_ref;
merge_prompt += "\n   strategy=rebase：git rebase ";
merge_prompt += fetch_out.fetched_ref;
merge_prompt += "\n3. 无冲突：conflict_files=[] resolved_local=[] remaining_conflicts=[] ok=true\n";
merge_prompt += "4. 有冲突：git diff --name-only --diff-filter=U\n";
merge_prompt += "   a. 路径属于 protected_paths 或位于其目录下，或为仓库根目录 *.custom.yaml：\n";
merge_prompt += "      MERGE：git checkout --ours -- <path> && git add -- <path>（ours=本地当前分支）\n";
merge_prompt += "      记入 resolved_local\n";
merge_prompt += "      REBASE：勿盲目 --ours（此时 ours 常为上游）。优先 git checkout REBASE_HEAD -- <path>；不确定则 git rebase --abort 且 ok=false，建议改 merge\n";
merge_prompt += "   b. others/ 下路径默认【不】本地优先，留给 remaining_conflicts\n";
merge_prompt += "   c. 非保护冲突：不要编造内容；列入 remaining_conflicts；ok=false；尽量保持可恢复，勿轻易 merge --abort（除非无法继续）\n";
merge_prompt += "   d. 若保护冲突已全部处理且无剩余：确保无 unmerged 后完成 merge\n";
merge_prompt += "5. strategy_used、message（中文）\n";
merge_prompt += "灾难时 merge --abort / rebase --abort，ok=false，指向 backup_branch。\n";
merge_prompt += "只返回 schema。\n";

let merge_r = agent(merge_prompt, #{
    label: "merge-upstream",
    capability_mode: "execute",
    output_schema: merge_schema,
});

if merge_r == () || !merge_r.success || merge_r.output == () {
    complete(#{
        success: false,
        phase: "Merge",
        error: "Merge agent 失败。",
        backup_branch: backup_branch,
        rollback_hint: "检查 git status。若 merge 进行中：git merge --abort。完整恢复：git reset --hard " + backup_branch + "（会丢弃未提交工作）。",
    });
}

let merge_out = merge_r.output;
log("Merge: ok=" + merge_out.ok.to_string() + " strategy=" + merge_out.strategy_used);

if merge_out.ok != true {
    let rem = merge_out.remaining_conflicts;
    let has_remaining = rem != () && rem.len() > 0;
    if has_remaining {
        let cmsg = "";
        cmsg += "上游同步已暂停：仍有未解决的【非保护】冲突。\n";
        cmsg += "保护路径已尽量保留本地（resolved_local）。\n";
        cmsg += "remaining_conflicts: ";
        cmsg += json_encode(rem);
        cmsg += "\n\n请手动编辑并 git add 后，在 /workflows resume。\n";
        cmsg += "彻底放弃：git merge --abort 或 git rebase --abort；或 git reset --hard ";
        cmsg += backup_branch;
        cmsg += "\n";
        await_user("user", cmsg);

        let finish_prompt = "";
        finish_prompt += "用户已尝试解决剩余冲突。检查 git status。\n";
        finish_prompt += "若仍有 unmerged：ok=false 并列出 remaining_conflicts。\n";
        finish_prompt += "若已全部解决但未完成：merge 用 git commit --no-edit；rebase 用 git rebase --continue。\n";
        finish_prompt += "禁止 push / reset --hard；保护路径不要用上游覆盖。\n";
        finish_prompt += "protected_paths: ";
        finish_prompt += protected_paths_json;
        finish_prompt += "\nstrategy_used 填 ";
        finish_prompt += strategy;
        finish_prompt += "。message 用中文。返回 merge schema。\n";

        let finish_r = agent(finish_prompt, #{
            label: "finish-merge",
            capability_mode: "execute",
            output_schema: merge_schema,
        });
        if finish_r == () || !finish_r.success || finish_r.output == () {
            complete(#{
                success: false,
                phase: "Merge",
                error: "手动解决冲突后的 finish-merge 失败。",
                backup_branch: backup_branch,
                rollback_hint: "git merge --abort 或 git rebase --abort；或 git reset --hard " + backup_branch,
            });
        }
        merge_out = finish_r.output;
    }
    if merge_out.ok != true {
        complete(#{
            success: false,
            phase: "Merge",
            error: merge_out.message,
            conflict_files: merge_out.conflict_files,
            remaining_conflicts: merge_out.remaining_conflicts,
            resolved_local: merge_out.resolved_local,
            backup_branch: backup_branch,
            rollback_hint: "中止：git merge --abort / git rebase --abort。完整恢复：git reset --hard " + backup_branch + "（破坏性）。",
        });
    }
}

// =============================================================================
// Phase: Verify
// =============================================================================
phase("Verify");

let verify_prompt = "";
verify_prompt += "你在校验刚完成的本地上游同步。禁止 push / 再次 merge。\n";
verify_prompt += "用 run_terminal_command 与 read_file，结论必须有证据。\n\n";
verify_prompt += "上下文：\n";
verify_prompt += "- backup_branch: ";
verify_prompt += json_encode(backup_branch);
verify_prompt += "\n- fingerprint_file: ";
verify_prompt += json_encode(fingerprint_file);
verify_prompt += "\n- protected_paths: ";
verify_prompt += protected_paths_json;
verify_prompt += "\n- run_lint: ";
verify_prompt += run_lint.to_string();
verify_prompt += "\n- fetched_ref: ";
verify_prompt += json_encode(fetch_out.fetched_ref);
verify_prompt += "\n- resolved_local: ";
verify_prompt += json_encode(merge_out.resolved_local);
verify_prompt += "\n\n必须检查：\n";
verify_prompt += "1. git status --porcelain 与 -sb；无 MERGE_HEAD/rebase。clean=true 仅当无阻塞性已跟踪变更且无进行中操作（.grok/backups 等 untracked 可忽略）。\n";
verify_prompt += "2. 按 fingerprint_file 重算保护路径指纹；任一保护路径内容变化 → protected_ok=false，列入 protected_failures。\n";
verify_prompt += "3. diff_stat：git diff --stat ";
verify_prompt += backup_branch;
verify_prompt += "..HEAD\n";
verify_prompt += "4. resurrected_paths：在 backup 树中不存在（或为删除状态）但 HEAD 中又出现的路径——即「本地删过又被上游 merge 带回来」的文件；用 git diff --diff-filter=A --name-only ";
verify_prompt += backup_branch;
verify_prompt += "..HEAD 并结合 backup 侧是否曾删除来判断，尽量列出。\n";
verify_prompt += "5. run_lint=true 且存在 others/script/Makefile 时：make -C others/script/ lint；否则 lint_ran=false 且 lint_ok=true\n";
verify_prompt += "6. rollback_hint 必须含如何恢复 backup_branch（中文）\n";
verify_prompt += "7. ok=true 仅当 clean && protected_ok && lint_ok\n";
verify_prompt += "8. summary：中文短摘要\n";
verify_prompt += "只返回 schema。\n";

let verify_r = agent(verify_prompt, #{
    label: "verify-sync",
    capability_mode: "execute",
    output_schema: verify_schema,
});

if verify_r == () || !verify_r.success || verify_r.output == () {
    complete(#{
        success: false,
        phase: "Verify",
        error: "Verify 失败；工作区可能已 merge，请人工检查。",
        backup_branch: backup_branch,
        rollback_hint: "git reset --hard " + backup_branch + "（会丢弃 merge 后状态，破坏性）。",
    });
}

let verify_out = verify_r.output;
log("Verify: ok=" + verify_out.ok.to_string() + " clean=" + verify_out.clean.to_string() + " protected_ok=" + verify_out.protected_ok.to_string());

// --- 中文报告 ---
let report = "";
report += "# sync-upstream 同步报告\n\n";
report += "## 结果\n\n";
if verify_out.ok == true {
    report += "**成功** — 已在本地 merge 上游；受保护路径指纹一致；**未执行 push**。\n\n";
} else {
    report += "**校验失败** — 见下文；可使用备份分支回滚。\n\n";
}
report += "| 项 | 值 |\n|----|----|\n";
report += "| 当前分支 | ";
report += inspect.current_branch;
report += " |\n| 同步前 SHA | ";
report += inspect.head_sha;
report += " |\n| 上游 ref | ";
report += fetch_out.fetched_ref;
report += " |\n| 策略 | ";
report += merge_out.strategy_used;
report += " |\n| 备份分支 | ";
report += backup_branch;
report += " |\n| 指纹文件 | ";
report += fingerprint_file;
report += " |\n\n## 保护路径\n\n";
report += "```\n";
report += protected_paths_json;
report += "\n```\n\n## Merge\n\n";
report += "- 说明：";
report += merge_out.message;
report += "\n- 已本地优先解决：";
report += json_encode(merge_out.resolved_local);
report += "\n- 曾剩余冲突：";
report += json_encode(merge_out.remaining_conflicts);
report += "\n\n## 变更摘要\n\n";
report += "```\n";
report += verify_out.diff_stat;
report += "\n```\n\n";
report += "### 可能被上游「复活」的路径\n\n";
report += json_encode(verify_out.resurrected_paths);
report += "\n\n## 校验\n\n";
report += "- clean: ";
report += verify_out.clean.to_string();
report += "\n- protected_ok: ";
report += verify_out.protected_ok.to_string();
report += "\n- protected_failures: ";
report += json_encode(verify_out.protected_failures);
report += "\n- lint_ran / lint_ok: ";
report += verify_out.lint_ran.to_string();
report += " / ";
report += verify_out.lint_ok.to_string();
report += "\n- 摘要：";
report += verify_out.summary;
report += "\n\n## 回滚\n\n";
report += verify_out.rollback_hint;
report += "\n\n完整恢复到同步前（**破坏性**，会丢掉 merge 后提交与未提交改动）：\n\n";
report += "```bash\ngit reset --hard ";
report += backup_branch;
report += "\n```\n\n";
report += "本 workflow **不会** push。若需更新个人 fork：`git push mine HEAD`（请自行确认）。\n";

let report_path = write_scratch_file("sync-upstream-report.md", report);

if verify_out.ok != true {
    complete(#{
        success: false,
        path: report_path,
        report: report,
        backup_branch: backup_branch,
        protected_failures: verify_out.protected_failures,
        resurrected_paths: verify_out.resurrected_paths,
        rollback_hint: verify_out.rollback_hint,
        summary: verify_out.summary,
    });
}

complete(#{
    success: true,
    path: report_path,
    report: report,
    backup_branch: backup_branch,
    upstream_ref: fetch_out.fetched_ref,
    strategy: merge_out.strategy_used,
    resolved_local: merge_out.resolved_local,
    resurrected_paths: verify_out.resurrected_paths,
    summary: verify_out.summary,
    rollback_hint: verify_out.rollback_hint,
});
