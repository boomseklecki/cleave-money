"""Pure unit test for `fetch_friends` normalization (no network - a fake SDK client)."""
from types import SimpleNamespace

from app.integrations.splitwise import client as sw_client


def _balance(currency, amount):
    return SimpleNamespace(getCurrencyCode=lambda: currency, getAmount=lambda: amount)


def _friend(uid, first, last, balances, *, email=None):
    return SimpleNamespace(
        getId=lambda: uid,
        getFirstName=lambda: first,
        getLastName=lambda: last,
        getEmail=lambda: email,
        getCustomPicture=lambda: False,  # → picture None (avoids the generic placeholder)
        getPicture=lambda: None,
        getBalances=lambda: balances,
    )


def _client(friends):
    return SimpleNamespace(getFriends=lambda: friends)


def test_normalizes_friends_with_balances():
    client = _client([
        _friend(200, "Bob", "Guy", [_balance("USD", "2811.59")], email="n@x.com"),
        _friend(300, "Mac", "Whittles", [_balance("USD", "-50.0")]),
    ])
    out = sw_client.fetch_friends(client)
    assert out == [
        {"splitwise_id": "200", "first_name": "Bob", "last_name": "Guy", "email": "n@x.com",
         "picture": None, "balances": [{"currency": "USD", "amount": "2811.59"}], "groups": []},
        {"splitwise_id": "300", "first_name": "Mac", "last_name": "Whittles", "email": None,
         "picture": None, "balances": [{"currency": "USD", "amount": "-50.0"}], "groups": []},
    ]


def test_friend_with_no_balances():
    out = sw_client.fetch_friends(_client([_friend(400, "Zed", "", [])]))
    assert out[0]["balances"] == []
    assert out[0]["splitwise_id"] == "400"


def test_no_friends():
    assert sw_client.fetch_friends(_client([])) == []


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
