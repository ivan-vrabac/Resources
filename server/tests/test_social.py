"""Phase 1: profiles, contacts, search, chat."""
import main
from helpers import call, client, new_player


def test_profile_is_public_but_not_private():
    a_hid, a_sid, a_name = new_player("prof")
    b_hid, b_sid, b_name = new_player("view")
    me = call("/api/v1/social/profile", a_sid)["profile"]
    assert me["isMe"] and "credits" in me and me["name"] == a_name.lower()
    other = call("/api/v1/social/profile", b_sid, pid=me["pid"])["profile"]
    assert not other["isMe"]
    for private in ("credits", "xp", "hID", "lat", "lng", "lager", "inventory"):
        assert private not in other
    assert a_hid not in str(other)            # internal id never exposed


def test_unknown_pid_and_auth():
    _, sid, _ = new_player("unk")
    assert call("/api/v1/social/profile", sid, pid="doesnotexist")["code"] == "no_player"
    assert call("/api/v1/social/profile", "garbage")["code"] == "auth"


def test_contacts_conflicts_and_search():
    a_hid, a_sid, _ = new_player("cona")
    b_hid, b_sid, b_name = new_player("conb")
    b_pid = call("/api/v1/social/profile", b_sid)["profile"]["pid"]
    found = call("/api/v1/social/search", a_sid, q=b_name[:6])["players"]
    assert any(p["pid"] == b_pid for p in found)
    assert call("/api/v1/social/contact", a_sid, pid=b_pid, kind="friend")["relations"] == ["friend"]
    assert call("/api/v1/social/contact", a_sid, pid=b_pid, kind="watch")["relations"] == ["friend", "watch"]
    # blacklisting removes friend
    assert call("/api/v1/social/contact", a_sid, pid=b_pid, kind="blacklist")["relations"] == ["blacklist", "watch"]
    lists = call("/api/v1/social/contacts", a_sid)["contacts"]
    assert [c["pid"] for c in lists["blacklist"]] == [b_pid] and lists["friend"] == []
    assert call("/api/v1/social/contact", a_sid, pid=b_pid, kind="blacklist", action="remove")["relations"] == ["watch"]
    a_pid = call("/api/v1/social/profile", a_sid)["profile"]["pid"]
    assert call("/api/v1/social/contact", a_sid, pid=a_pid, kind="friend")["code"] == "bad_input"
    assert call("/api/v1/social/search", a_sid, q="%")["code"] == "bad_input"


def test_chat_order_history_blocking_and_rate_limit():
    a_hid, a_sid, _ = new_player("chata")
    b_hid, b_sid, _ = new_player("chatb")
    ids = [call("/api/v1/chat/send", a_sid, msg=f"hello {i}")["id"] for i in range(3)]
    assert ids == sorted(ids)
    msgs = call("/api/v1/chat/messages", b_sid, after=ids[0] - 1)["messages"]
    assert [m["msg"] for m in msgs][-3:] == ["hello 0", "hello 1", "hello 2"]
    older = call("/api/v1/chat/messages", b_sid, before=ids[2], limit=1)["messages"]
    assert [m["msg"] for m in older] == ["hello 1"]
    # duplicate + rate limit
    assert call("/api/v1/chat/send", a_sid, msg="hello 2")["code"] == "duplicate"
    codes = [call("/api/v1/chat/send", a_sid, msg=f"spam {i}").get("code") for i in range(5)]
    assert "rate_limited" in codes
    # blacklist hides the sender for the viewer only
    a_pid = call("/api/v1/social/profile", a_sid)["profile"]["pid"]
    call("/api/v1/social/contact", b_sid, pid=a_pid, kind="blacklist")
    assert all(m["pid"] != a_pid for m in call("/api/v1/chat/messages", b_sid)["messages"])
    assert any(m["pid"] == a_pid for m in call("/api/v1/chat/messages", a_sid)["messages"])
    assert call("/api/v1/chat/send", b_sid, msg="x" * 301)["code"] == "bad_input"
    assert call("/api/v1/chat/messages", b_sid)["rules"]


def test_private_messages_threads_read_and_block():
    a, a_sid, a_name = new_player("dma")
    b, b_sid, b_name = new_player("dmb")
    a_pid = call("/api/v1/social/profile", a_sid)["profile"]["pid"]
    b_pid = call("/api/v1/social/profile", b_sid)["profile"]["pid"]
    assert call("/api/v1/chat/dm/send", a_sid, pid=b_pid, msg="hello b")["err"] == 0
    th = call("/api/v1/chat/dm/threads", b_sid)
    assert th["unread"] == 1 and th["threads"][0]["name"] == a_name and th["threads"][0]["last"] == "hello b"
    conv = call("/api/v1/chat/dm/messages", b_sid, pid=a_pid)
    assert [m["msg"] for m in conv["messages"]] == ["hello b"] and not conv["messages"][0]["isMe"]
    assert call("/api/v1/chat/dm/threads", b_sid)["unread"] == 0                 # read now
    assert a not in str(th) and a not in str(conv)
    call("/api/v1/social/contact", b_sid, pid=a_pid, kind="blacklist")
    assert call("/api/v1/chat/dm/send", a_sid, pid=b_pid, msg="again")["code"] == "blocked"
    assert call("/api/v1/chat/dm/send", a_sid, pid=a_pid, msg="me")["code"] == "bad_input"


def test_social_badge_counts_mentions_and_private_messages():
    a_hid, a_sid, a_name = new_player("bdga")
    b_hid, b_sid, b_name = new_player("bdgb")
    seen = call("/api/v1/chat/unread", a_sid)["latestId"]
    call("/api/v1/chat/send", b_sid, msg="hello everyone")
    import time; time.sleep(2.1)
    call("/api/v1/chat/send", b_sid, msg=f"hey @{a_name} look")
    a_pid = call("/api/v1/social/profile", a_sid)["profile"]["pid"]
    call("/api/v1/chat/dm/send", b_sid, pid=a_pid, msg="private hi")
    r = call("/api/v1/chat/unread", a_sid, seen=seen)
    assert r["unread"] == 2 and r["mentions"] == 1 and r["dm"] == 1
    b_pid = call("/api/v1/social/profile", b_sid)["profile"]["pid"]
    call("/api/v1/chat/dm/messages", a_sid, pid=b_pid)          # reading clears it
    assert call("/api/v1/chat/unread", a_sid, seen=r["latestId"])["dm"] == 0

