class ProviderVerificationError(Exception):
    """Raised when an Apple/Google/Splitwise token fails verification."""


def verified_email(claims: dict) -> str | None:
    """The token's email claim, but only when the provider hasn't marked it unverified. Apple sends
    `email_verified` as a string ("true"/"false"); Google as a bool. We drop the email on an explicit
    false so an unverified address can't drive identity linking or the sign-in allowlist. (The token is
    provider-signed, so the email can't be tampered with - this just refuses unverified ones.)"""
    email = claims.get("email")
    verified = claims.get("email_verified")
    if email is not None and verified is not None and str(verified).lower() == "false":
        return None
    return email
