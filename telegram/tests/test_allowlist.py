import json

import pytest

from headlong_telegram.allowlist import Allowlist, AllowlistError


def test_approve_revoke_round_trip(tmp_path):
    al = Allowlist(tmp_path / "allowlist.json")
    assert not al.is_approved(7)
    al.approve(7, "Dana")
    assert al.is_approved(7)
    assert al.revoke(7)
    assert not al.is_approved(7)
    assert not al.revoke(7)


def test_persistence(tmp_path):
    path = tmp_path / "allowlist.json"
    Allowlist(path).approve(7, "Dana")
    assert Allowlist(path).is_approved(7)


def test_pending_notifies_once_per_interval(tmp_path):
    al = Allowlist(tmp_path / "allowlist.json")
    assert al.note_pending(9, "Stranger")
    assert not al.note_pending(9, "Stranger")  # rate limited


def test_denied_never_renotifies(tmp_path):
    al = Allowlist(tmp_path / "allowlist.json")
    al.note_pending(9, "Stranger")
    al.deny(9)
    assert not al.note_pending(9, "Stranger")
    assert not al.is_approved(9)


def test_approve_clears_pending_and_denied(tmp_path):
    al = Allowlist(tmp_path / "allowlist.json")
    al.note_pending(9, "Dana Kim")
    al.deny(9)
    al.approve(9)
    assert al.is_approved(9)


def test_approve_keeps_pending_label(tmp_path):
    al = Allowlist(tmp_path / "allowlist.json")
    al.note_pending(9, "Dana Kim")
    al.approve(9)
    assert "Dana Kim" in al.summary()


def test_corrupt_file_starts_empty(tmp_path):
    path = tmp_path / "allowlist.json"
    path.write_text("not json{")
    al = Allowlist(path)
    assert not al.is_approved(1)
    al.approve(1)
    assert Allowlist(path).is_approved(1)


# -- the perimeter is read defensively ---------------------------------------
# Each of these is a hand-edited or half-written file. The old loader parsed
# the whole document in one try/except, so one bad element took the rest with
# it, or a string was iterated into the ids it happened to contain.

def test_denied_written_as_one_string_is_one_id(tmp_path):
    """'denied': '123456' is one id. Iterating the string denies 1..6 instead,
    and the save writes those six ids back, losing the real deny."""
    path = tmp_path / "allowlist.json"
    path.write_text('{"approved": {}, "denied": "123456", "pending": {}}')
    al = Allowlist(path)
    assert not al.is_approved(123456)
    assert "123456" in al._denied
    assert al._denied == {"123456"}  # not {"1","2","3","4","5","6"}
    al.approve(7)
    on_disk = json.loads(path.read_text())
    assert on_disk["denied"] == ["123456"]


def test_one_bad_pending_entry_keeps_its_neighbours(tmp_path):
    """A bad last_notified must not drop every pending entry: the admin is then
    re-prompted about senders they were already told about."""
    path = tmp_path / "allowlist.json"
    path.write_text(
        '{"approved": {}, "denied": [], "pending": {'
        '"9": {"label": "Real", "last_notified": 9999999999999},'
        '"10": {"label": "Bad", "last_notified": "yesterday"}}}'
    )
    al = Allowlist(path)
    assert set(al._pending) == {"9", "10"}
    # the good one keeps its timestamp, so it stays rate limited
    assert not al.note_pending(9, "Real")


def test_approved_as_a_list_still_approves(tmp_path):
    """'approved': [7, 8] is what a person hand-editing would write."""
    path = tmp_path / "allowlist.json"
    path.write_text('{"approved": [7, 8], "denied": [], "pending": {}}')
    al = Allowlist(path)
    assert al.is_approved(7)
    assert al.is_approved(8)


def test_non_numeric_ids_are_dropped_not_read_as_other_ids(tmp_path):
    path = tmp_path / "allowlist.json"
    path.write_text('{"approved": {"abc": "Eve", "7": "Dana"}, "denied": [], "pending": {}}')
    al = Allowlist(path)
    assert al.is_approved(7)
    assert not al.is_approved(1)


def test_unreadable_file_is_moved_aside_not_overwritten(tmp_path):
    """Starting empty is safe for the perimeter but must not destroy what an
    operator might still recover by hand."""
    path = tmp_path / "allowlist.json"
    path.write_text('{"approved": {"7": "Dana"}')  # torn write
    al = Allowlist(path)
    assert not al.is_approved(7)
    assert not path.exists()
    aside = list(tmp_path.glob("allowlist.json.unreadable-*"))
    assert len(aside) == 1
    assert '"7"' in aside[0].read_text()
    al.approve(7)
    assert Allowlist(path).is_approved(7)


def test_save_failure_raises_and_rolls_back(tmp_path):
    """A swallowed save failure leaves the process believing an approve or deny
    took effect while the disk disagrees."""
    path = tmp_path / "allowlist.json"
    path.mkdir()  # every write raises IsADirectoryError
    al = Allowlist(path)
    with pytest.raises(AllowlistError):
        al.approve(7)
    assert not al.is_approved(7)  # rolled back, not half-applied


def test_save_failure_on_deny_rolls_back(tmp_path):
    path = tmp_path / "allowlist.json"
    path.mkdir()
    al = Allowlist(path)
    with pytest.raises(AllowlistError):
        al.deny(13)
    assert "13" not in al._denied
