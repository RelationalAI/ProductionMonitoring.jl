"""
This file contains utlility functions to scrub secrets from log messages. Currently it
handles only Azure SAS tokens. As we expand to include more secret types and cloud
providers, we should add functions accordingly.
"""

const SAS_TOKEN_REGEX = r"sig=[^&\"]+"
const REPLACEMENT = "*********************"

"""
    scrub_sas_token(log_message:AbstractString)

Given a log message containing a SAS token, return a sanitized version without the
confidential part (the signature). We could not find any authoritative documentation on the
SAS token format, so it is inferred from this example in the docs:
https://docs.microsoft.com/en-us/azure/storage/common/storage-sas-overview#sas-token
"""
function scrub_sas_token(log_message::AbstractString)
    return replace(log_message, SAS_TOKEN_REGEX => REPLACEMENT)
end

"""
    scrub_secrets(log_message:AbstractString)

Scrub confidential information from a log message.
Currently handles SAS tokens only.
"""
function scrub_secrets(log_message::AbstractString)
    scrubbed_message = scrub_sas_token(log_message)
    # Scrub more secret types here eventually.
    return scrubbed_message
end
