// Sample JSON fixtures captured from real email-cli output, used by the
// decode tests to catch any drift in the wire contract.

enum Fixtures {
    /// `email-cli account list --json`
    static let accountList = """
    {
      "status": "success",
      "version": "1",
      "data": [
        {"email":"boris@paperfoot.com","profile_name":"local","is_default":true,"signature":"","display_name":null,"created_at":"2026-04-02 23:26:37","updated_at":"2026-04-02 23:26:37"},
        {"email":"boris@199.clinic","profile_name":"local","is_default":false,"signature":"","display_name":null,"created_at":"2026-04-02 23:38:29","updated_at":"2026-04-02 23:38:29"}
      ]
    }
    """

    /// `email-cli inbox list --json --limit 2`
    static let inboxList = """
    {
      "status": "success",
      "version": "1",
      "data": {
        "messages": [
          {"id":77,"remote_id":"abc","direction":"received","account_email":"boris@paperfoot.com",
           "from_addr":"Resend <notifications@resend.com>","to":["boris@paperfoot.com"],"cc":[],"bcc":[],
           "subject":"Welcome","text_body":"Hi","html_body":null,"rfc_message_id":"<x@y>","in_reply_to":null,
           "last_event":"received","is_read":false,"archived":false,
           "created_at":"2026-04-17T20:00:59.710Z","synced_at":"2026-04-17T20:01:00.000Z","reply_to":[],"references":[]}
        ],
        "has_more": true,
        "next_cursor": 77
      }
    }
    """

    /// `email-cli inbox stats --json`
    static let stats = """
    {"status":"success","version":"1","data":{"inbox":33,"unread":7,"sent":50,"archived":0,"total":83}}
    """

    /// `email-cli inbox read 77 --json --mark-read false`
    static let messageDetail = """
    {"status":"success","version":"1","data":{
      "id":77,"remote_id":"abc","direction":"received","account_email":"boris@paperfoot.com",
      "from_addr":"\\"Resend\\" <notifications@resend.com>",
      "to":["boris@paperfoot.com"],"cc":[],"bcc":[],"reply_to":[],
      "subject":"Re: Deploy","text_body":"Shipped","html_body":"<p>Shipped</p>",
      "rfc_message_id":"<x@y>","in_reply_to":"<a@b>","references":["<a@b>"],
      "last_event":"received","is_read":false,"archived":false,
      "created_at":"2026-04-17T20:00:59Z","synced_at":"2026-04-17T20:01:00Z"
    }}
    """

    /// `email-cli inbox list --json` with every v0.7.0 field populated.
    /// Pins the schema so a future shape drift fails loudly here.
    static let inboxListV07 = """
    {
      "status": "success",
      "version": "1",
      "data": {
        "messages": [
          {"id":101,"remote_id":"xyz","direction":"received","account_email":"boris@paperfoot.com",
           "from_addr":"Newsletter <hi@newsletter.com>","to":["boris@paperfoot.com"],"cc":[],"bcc":[],
           "subject":"Weekly digest","text_body":"Long body...","text_preview":"Short two-line preview of the body...",
           "html_body":null,"rfc_message_id":"<x@y>","in_reply_to":null,
           "last_event":"received","is_read":false,"archived":false,"has_attachments":true,
           "starred":true,"snoozed_until":"2026-04-21T08:00:00Z",
           "list_unsubscribe":"<https://unsubscribe.example/xyz>, <mailto:u@x.com?subject=unsub>",
           "created_at":"2026-04-17T20:00:59.710Z","synced_at":"2026-04-17T20:01:00.000Z","reply_to":[],"references":[]}
        ],
        "has_more": false,
        "next_cursor": null
      }
    }
    """
}
