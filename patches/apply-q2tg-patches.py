#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Q2TG 镜像 bundle 补丁（A / B / C 三个）

背景：
    ghcr.io/clansty/q2tg:sleepyfox 镜像里的 /app/build/index.js 比上游源码旧，
    在 SnowLuma 组合下有 3 个必现 bug。做法是导出 bundle、打补丁、再用 volume 挂载覆盖。

用法：
    cd /opt/q2tg
    mkdir -p patched
    # 1) 先注释掉 compose 里 ./patched/index.js 的挂载，再启动容器
    docker compose up -d q2tg
    # 2) 从容器里导出 bundle（-aq 而非 -q：容器处于 Exited 时 -q 取不到 ID）
    docker cp "$(docker compose ps -aq q2tg):/app/build/index.js" patched/index.js.orig
    cp patched/index.js.orig patched/index.js
    # 3) 打补丁
    python3 apply-q2tg-patches.py
    # 4) 校验
    node --check patched/index.js
    grep -c 'length - input.length' patched/index.js            # 期望 0
    grep -c 'friend.uin ?? friend.user_id' patched/index.js     # 期望 1
    grep -c 'me.username || this.tgBot.me.id' patched/index.js  # 期望 1
    # 5) 恢复 compose 挂载，docker compose up -d q2tg

补丁说明：
    A  getDisplay()          删掉未定义的 length 引用，修 /setup 验证码崩溃
    B  getFriendsWithCluster()  friend.uin ?? friend.user_id、friend.nick ?? friend.nickname，
                              修 /addfriend 显示 undefined (NaN)
    C  createGroupAndLink()  inviteMember 优先用 username，修邀请 bot 失败
                              （Could not find the input entity for PeerUser）

注意：
    - 每个替换都要求「恰好匹配 1 次」，匹配不上直接退出，宁可不动也不乱打。
    - 镜像一升级，bundle 内容可能变，本脚本会明确报错，届时按新 bundle 重新确认。
    - 重复执行本脚本会因 A 的原文已被替换而中止（这是有意的防呆）。
"""

import argparse
import sys

# 补丁 A：/setup 验证码崩溃（ReferenceError: length is not defined）
A_OLD = """    function getDisplay() {
      const leftLength = length - input.length;
      let display = Array.from(input);
      leftLength > 0 && display.push(SYMBOL_INPUT);
      leftLength > 1 && display.push(...SYMBOL_EMPTY.repeat(leftLength - 1));
      return `>>>  ${display.join(SYMBOL_SPACE)}  <<<`;
    }"""

A_NEW = """    function getDisplay() {
      let display = Array.from(input);
      display.push(SYMBOL_INPUT);
      return `>>>  ${display.join(SYMBOL_SPACE)}  <<<`;
    }"""

# 补丁 B1：好友昵称 / 号码字段兼容（NapCat -> OneBot 标准字段）
B1_OLD = """            nickname: friend.nick,
            uid: parseInt(friend.uin),"""
B1_NEW = """            nickname: friend.nick ?? friend.nickname,
            uid: parseInt(friend.uin ?? friend.user_id),"""

# 补丁 B2：好友分组里另一处 uid 解析
B2_OLD = """              uid: parseInt(it.uin),"""
B2_NEW = """              uid: parseInt(it.uin ?? it.user_id),"""

# 补丁 C：创建群时邀请 bot，优先用 username（userbot 实体缓存里没有数字 ID）
C_OLD = "await chat.inviteMember(this.tgBot.me.id);"
C_NEW = "await chat.inviteMember(this.tgBot.me.username || this.tgBot.me.id);"

PATCHES = [
    ("A", A_OLD, A_NEW),
    ("B1", B1_OLD, B1_NEW),
    ("B2", B2_OLD, B2_NEW),
    ("C", C_OLD, C_NEW),
]


def sub_once(text: str, old: str, new: str, tag: str) -> str:
    count = text.count(old)
    if count != 1:
        sys.exit(
            f"[{tag}] 期望匹配 1 次，实际 {count} 次 —— bundle 与本教程不符，不要继续。\n"
            f"       可能原因：镜像已升级、bundle 已打过补丁、或导出的是错的文件。"
        )
    return text.replace(old, new)


def main() -> None:
    parser = argparse.ArgumentParser(description="给 Q2TG 镜像 bundle 打 A/B/C 补丁")
    parser.add_argument(
        "--bundle",
        default="patched/index.js",
        help="bundle 路径（默认 patched/index.js）",
    )
    args = parser.parse_args()

    try:
        text = open(args.bundle, encoding="utf-8").read()
    except FileNotFoundError:
        sys.exit(f"找不到 {args.bundle}：先按说明从容器导出 bundle 到该路径")

    for tag, old, new in PATCHES:
        text = sub_once(text, old, new, tag)
        print(f"[{tag}] 已替换")

    with open(args.bundle, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"patched: {args.bundle}")
    print("下一步：node --check 校验语法，再按教程恢复 compose 挂载并重启容器")


if __name__ == "__main__":
    main()
