"""Identity selection: the env var, then the `default` symlink, then an error."""

import pytest

from headlong_slack import config


def _identity(root, name):
    d = root / ".identities" / name
    d.mkdir(parents=True)
    (d / "info.txt").write_text("an identity\n")
    return d


@pytest.fixture(autouse=True)
def _tokens(monkeypatch):
    monkeypatch.setenv("SLACK_BOT_TOKEN", "xoxb-test")
    monkeypatch.setenv("SLACK_APP_TOKEN", "xapp-test")
    monkeypatch.delenv("HEADLONG_SLACK_IDENTITY", raising=False)
    monkeypatch.delenv("SHELLM_SLACK_IDENTITY", raising=False)
    # config.load mkdirs the state dir, so an ambient override would make
    # these tests write outside tmp_path.
    monkeypatch.delenv("HEADLONG_SLACK_STATE_DIR", raising=False)
    monkeypatch.delenv("SHELLM_SLACK_STATE_DIR", raising=False)


def test_falls_back_to_the_default_symlink(tmp_path):
    _identity(tmp_path, "ada")
    (tmp_path / ".identities" / "default").symlink_to("ada")

    assert config.load(tmp_path).identity == "ada"


def test_follows_only_the_immediate_link(tmp_path):
    """The default's own target is the name `identity default` recorded, and
    the one persona reports — `resolve()` would walk past it to the end of the
    chain and return a name no one configured.

    The chained identity here is the fixture that tells the two apart, not an
    endorsement: a symlinked identity dir is invisible to the web scan, so its
    messages 404 however the name was chosen (#66).
    """
    elsewhere = tmp_path / "elsewhere" / "current"
    elsewhere.mkdir(parents=True)
    (elsewhere / "info.txt").write_text("an identity\n")
    identities = tmp_path / ".identities"
    identities.mkdir()
    (identities / "ada").symlink_to(elsewhere)
    (identities / "default").symlink_to("ada")

    assert config.load(tmp_path).identity == "ada"

def test_env_var_wins_over_the_default_symlink(tmp_path, monkeypatch):
    _identity(tmp_path, "ada")
    _identity(tmp_path, "bo")
    (tmp_path / ".identities" / "default").symlink_to("ada")
    monkeypatch.setenv("HEADLONG_SLACK_IDENTITY", "bo")

    assert config.load(tmp_path).identity == "bo"


def test_no_var_and_no_default_names_the_variable(tmp_path):
    _identity(tmp_path, "ada")

    with pytest.raises(SystemExit) as exc:
        config.load(tmp_path)
    assert "HEADLONG_SLACK_IDENTITY" in str(exc.value)


def test_a_dangling_default_link_names_the_link(tmp_path):
    """A broken default must not surface as "identity not found ... identity
    new <name>" — that advice creates a second identity instead of fixing the
    link."""
    (tmp_path / ".identities").mkdir()
    (tmp_path / ".identities" / "default").symlink_to("ghost")

    with pytest.raises(SystemExit) as exc:
        config.load(tmp_path)
    assert "default identity link" in str(exc.value)
    assert "ghost" in str(exc.value)



def test_join_backfill_defaults_to_twenty(tmp_path, monkeypatch):
    _identity(tmp_path, "ada")
    (tmp_path / ".identities" / "default").symlink_to("ada")
    monkeypatch.delenv("SLACK_THREAD_JOIN_BACKFILL", raising=False)
    assert config.load(tmp_path).thread_join_backfill == 20


def test_join_backfill_zero_disables(tmp_path, monkeypatch):
    _identity(tmp_path, "ada")
    (tmp_path / ".identities" / "default").symlink_to("ada")
    monkeypatch.setenv("SLACK_THREAD_JOIN_BACKFILL", "0")
    assert config.load(tmp_path).thread_join_backfill == 0


def test_join_backfill_clamps_to_fifty(tmp_path, monkeypatch):
    _identity(tmp_path, "ada")
    (tmp_path / ".identities" / "default").symlink_to("ada")
    monkeypatch.setenv("SLACK_THREAD_JOIN_BACKFILL", "999")
    assert config.load(tmp_path).thread_join_backfill == 50


def test_join_backfill_garbage_falls_back(tmp_path, monkeypatch):
    _identity(tmp_path, "ada")
    (tmp_path / ".identities" / "default").symlink_to("ada")
    monkeypatch.setenv("SLACK_THREAD_JOIN_BACKFILL", "nope")
    assert config.load(tmp_path).thread_join_backfill == 20


@pytest.mark.parametrize("raw", ["1", "true", "TRUE", "yes", "on", " on "])
def test_bool_env_truthy_words(monkeypatch, raw):
    monkeypatch.setenv("SLACK_THREAD_FOLLOWUPS", raw)
    assert config._bool_env("SLACK_THREAD_FOLLOWUPS") is True


@pytest.mark.parametrize("raw", ["0", "false", "False", "no", "off", " 0"])
def test_bool_env_falsy_words(monkeypatch, raw):
    monkeypatch.setenv("SLACK_THREAD_FOLLOWUPS", raw)
    assert config._bool_env("SLACK_THREAD_FOLLOWUPS") is False


def test_bool_env_unset_and_empty_are_the_default(monkeypatch):
    monkeypatch.delenv("SLACK_THREAD_FOLLOWUPS", raising=False)
    assert config._bool_env("SLACK_THREAD_FOLLOWUPS") is False
    assert config._bool_env("SLACK_THREAD_FOLLOWUPS", default=True) is True
    monkeypatch.setenv("SLACK_THREAD_FOLLOWUPS", "")
    assert config._bool_env("SLACK_THREAD_FOLLOWUPS") is False


def test_bool_env_typo_warns_and_falls_back(monkeypatch, capsys):
    monkeypatch.setenv("SLACK_THREAD_FOLLOWUPS", "nope")
    assert config._bool_env("SLACK_THREAD_FOLLOWUPS") is False
    err = capsys.readouterr().err
    assert "SLACK_THREAD_FOLLOWUPS" in err and "not a boolean" in err


def test_thread_followups_false_means_off(tmp_path, monkeypatch):
    """The symptom: the old rule read every non-empty, non-'0' value as ON,
    so =false, =no and =off all turned follow-ups ON."""
    _identity(tmp_path, "ada")
    (tmp_path / ".identities" / "default").symlink_to("ada")
    monkeypatch.setenv("SLACK_THREAD_FOLLOWUPS", "false")
    cfg = config.load(tmp_path)
    assert cfg.thread_followups is False
    monkeypatch.setenv("SLACK_THREAD_FOLLOWUPS", "1")
    assert config.load(tmp_path).thread_followups is True


# -- knobs that used to fail silently ---------------------------------------


def test_peer_list_takes_whitespace_and_newlines(monkeypatch):
    """A space-separated list parsed to the empty set before: the single token
    "U0AAA U0BBB" is not a user id, so peer hearing was silently off."""
    monkeypatch.setenv("SLACK_PEER_BOT_USERS", "U0C2G1517EC U0BN5FSURBN")
    assert config._peer_bot_users() == frozenset({"U0C2G1517EC", "U0BN5FSURBN"})
    monkeypatch.setenv("SLACK_PEER_BOT_USERS", "U0C2G1517EC\n\tU0BN5FSURBN,")
    assert config._peer_bot_users() == frozenset({"U0C2G1517EC", "U0BN5FSURBN"})


def test_peer_list_still_rejects_non_ids(monkeypatch):
    monkeypatch.setenv(
        "SLACK_PEER_BOT_USERS", "B0C15LE90KH, harris, u0lower, W0PEER1"
    )
    assert config._peer_bot_users() == frozenset({"W0PEER1"})


def test_int_typo_warns_and_falls_back(monkeypatch, capsys):
    monkeypatch.setenv("SLACK_PEER_MAX_TURNS", "four")
    assert config._int_env("SLACK_PEER_MAX_TURNS", 4, 0, 50) == 4
    err = capsys.readouterr().err
    assert "SLACK_PEER_MAX_TURNS" in err and "whole number" in err


def test_int_out_of_range_warns_with_the_value_used(monkeypatch, capsys):
    monkeypatch.setenv("SLACK_PEER_HOURLY_CAP", "5000")
    assert config._int_env("SLACK_PEER_HOURLY_CAP", 30, 0, 1000) == 1000
    err = capsys.readouterr().err
    assert "5000" in err and "1000" in err


def test_int_surrounding_space_is_accepted(monkeypatch, capsys):
    monkeypatch.setenv("SLACK_PEER_MAX_TURNS", " 6 ")
    assert config._int_env("SLACK_PEER_MAX_TURNS", 4, 0, 50) == 6
    assert capsys.readouterr().err == ""


def test_join_backfill_typo_warns(monkeypatch, capsys):
    monkeypatch.setenv("SLACK_THREAD_JOIN_BACKFILL", "nope")
    assert config._join_backfill_limit() == 20
    err = capsys.readouterr().err
    assert "SLACK_THREAD_JOIN_BACKFILL" in err


def test_peer_list_all_junk_warns_instead_of_going_quiet(monkeypatch, capsys):
    """Every bot post is dropped when this parses empty. That must be loud."""
    monkeypatch.setenv("SLACK_PEER_BOT_USERS", "u0lower, harris")
    assert config._peer_bot_users() == frozenset()
    err = capsys.readouterr().err
    assert "U0LOWER" in err.upper() and "nobody" in err


def test_peer_list_partly_junk_names_what_it_dropped(monkeypatch, capsys):
    monkeypatch.setenv("SLACK_PEER_BOT_USERS", "U0C2G1517EC,harris")
    assert config._peer_bot_users() == frozenset({"U0C2G1517EC"})
    assert "harris" in capsys.readouterr().err


def test_peer_list_unset_says_nothing(monkeypatch, capsys):
    monkeypatch.delenv("SLACK_PEER_BOT_USERS", raising=False)
    assert config._peer_bot_users() == frozenset()
    assert capsys.readouterr().err == ""
