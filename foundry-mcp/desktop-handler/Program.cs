// GIP Archive Open — giparchive: protocol handler (v1.0.0)
//
// Invoked by the OS/browser with one argument: a URI of the form
//     giparchive:v1?mid=<url-encoded Message-ID>&owa=<url-encoded OWA fallback URL>
//
// It locates the message in the user's Exchange Online Archive by Message-ID and
// opens it in classic Outlook desktop. If not found (or Outlook unavailable) it
// falls back to the OWA/webmail URL so the click never dead-ends.
//
// Design/security (see plans/OUTLOOK-DESKTOP-OPEN-PLAN.md §3, §6):
//   - INPUT IS REMOTE-TRIGGERABLE. The Message-ID is strictly validated against a
//     conservative pattern before use; anything else is a logged no-op.
//   - No shell/command execution with the input; the only Process.Start is the
//     https OWA fallback, which is itself validated as an outlook.office*.com URL.
//   - DASL value is single-quote-escaped (injection guard).
//   - Lookup key = PR_INTERNET_MESSAGE_ID proptag 0x1035001F equality (D0-proven);
//     scoped across every mounted "Online Archive -*" store (Message-ID is unique).
//   - AdvancedSearch completion event is unreliable under a headless host, so we
//     poll Search.Results with a pumped message loop.

using System;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace Gip.ArchiveOpen
{
    internal static class Program
    {
        // Conservative RFC 5322-ish Message-ID: <local@domain>, bounded length,
        // only characters legitimately seen in a Message-ID. No spaces/quotes/
        // angle-brackets beyond the required outer pair.
        private static readonly Regex MessageIdPattern =
            new Regex(@"^<[A-Za-z0-9!#$%&'*+/=?^_`{|}~.@=\-]{3,480}>$", RegexOptions.Compiled);

        private const string ProptagInternetMessageId =
            "http://schemas.microsoft.com/mapi/proptag/0x1035001F";

        private const int SearchTimeoutSeconds = 90;

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                if (args == null || args.Length == 0)
                {
                    Log("No argument supplied.");
                    return 1;
                }

                string raw = args[0];
                Log("Invoked: " + raw);

                if (!TryParse(raw, out string messageId, out string owaUrl))
                {
                    Log("Could not parse a giparchive URI from the argument.");
                    Fallback(owaUrl, "The link was malformed.");
                    return 1;
                }

                if (!MessageIdPattern.IsMatch(messageId))
                {
                    Log("Rejected Message-ID (failed validation): " + messageId);
                    Fallback(owaUrl, "The message identifier was not in a valid form.");
                    return 1;
                }

                bool opened = TryOpenInOutlook(messageId);
                if (opened)
                {
                    Log("Opened in Outlook: " + messageId);
                    return 0;
                }

                Log("Not found in Outlook archive; falling back to OWA.");
                Fallback(owaUrl, "That message was not found in your Outlook archive.");
                return 0;
            }
            catch (Exception ex)
            {
                Log("Unhandled: " + ex);
                return 1;
            }
        }

        // ── URI parse (manual; no System.Web dependency) ─────────────────────────
        private static bool TryParse(string raw, out string messageId, out string owaUrl)
        {
            messageId = null;
            owaUrl = null;
            if (string.IsNullOrWhiteSpace(raw)) return false;

            int scheme = raw.IndexOf("giparchive:", StringComparison.OrdinalIgnoreCase);
            if (scheme < 0) return false;
            string rest = raw.Substring(scheme + "giparchive:".Length);

            int q = rest.IndexOf('?');
            string query = q >= 0 ? rest.Substring(q + 1) : rest;

            foreach (string pair in query.Split('&'))
            {
                int eq = pair.IndexOf('=');
                if (eq <= 0) continue;
                string key = pair.Substring(0, eq);
                string val = Uri.UnescapeDataString(pair.Substring(eq + 1));
                if (key.Equals("mid", StringComparison.OrdinalIgnoreCase)) messageId = val;
                else if (key.Equals("owa", StringComparison.OrdinalIgnoreCase)) owaUrl = val;
            }
            return !string.IsNullOrEmpty(messageId);
        }

        // ── Outlook COM lookup + display ─────────────────────────────────────────
        private static bool TryOpenInOutlook(string messageId)
        {
            Type olType = Type.GetTypeFromProgID("Outlook.Application");
            if (olType == null)
            {
                Log("Outlook.Application ProgID not registered (Outlook not installed?).");
                return false;
            }

            dynamic ol = null;
            try
            {
                ol = Activator.CreateInstance(olType);   // attaches to running instance
                dynamic ns = ol.GetNamespace("MAPI");

                // Collect every mounted Online Archive store root as the search scope.
                var scopes = new System.Collections.Generic.List<string>();
                dynamic stores = ns.Stores;
                int storeCount = stores.Count;
                for (int i = 1; i <= storeCount; i++)
                {
                    dynamic store = stores[i];
                    string name = null;
                    try { name = (string)store.DisplayName; } catch { }
                    if (name != null && name.IndexOf("Online Archive", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        try
                        {
                            dynamic root = store.GetRootFolder();
                            scopes.Add("'" + (string)root.FolderPath + "'");
                        }
                        catch { }
                    }
                }

                if (scopes.Count == 0)
                {
                    Log("No 'Online Archive' store mounted in the profile.");
                    return false;
                }

                string scope = string.Join(",", scopes);
                string midEscaped = messageId.Replace("'", "''");   // DASL injection guard
                string filter = "\"" + ProptagInternetMessageId + "\" = '" + midEscaped + "'";
                Log("Scope: " + scope);

                dynamic search = ol.AdvancedSearch(scope, filter, true, "giparchive");

                // Poll Results with a pumped message loop (completion event is
                // unreliable in a headless STA host — D0 finding).
                DateTime deadline = DateTime.UtcNow.AddSeconds(SearchTimeoutSeconds);
                int count = 0;
                while (DateTime.UtcNow < deadline)
                {
                    Application.DoEvents();
                    System.Threading.Thread.Sleep(600);
                    try { count = search.Results.Count; } catch { count = 0; }
                    if (count > 0) break;
                }

                if (count < 1)
                {
                    Log("AdvancedSearch returned 0 within timeout.");
                    return false;
                }

                dynamic item = search.Results.Item(1);
                item.Display();   // opens the message window in Outlook
                return true;
            }
            catch (Exception ex)
            {
                Log("COM lookup failed: " + ex.Message);
                return false;
            }
        }

        // ── OWA fallback (validated https to outlook.office*.com only) ───────────
        private static void Fallback(string owaUrl, string reason)
        {
            if (IsAllowedOwaUrl(owaUrl))
            {
                try
                {
                    Log("Opening OWA fallback: " + owaUrl);
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(owaUrl) { UseShellExecute = true });
                    return;
                }
                catch (Exception ex) { Log("OWA fallback failed: " + ex.Message); }
            }
            MessageBox.Show(reason + "\r\n\r\nUse the \"Open in webmail\" link instead.",
                "GIP Archive Open", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static bool IsAllowedOwaUrl(string owaUrl)
        {
            if (string.IsNullOrEmpty(owaUrl)) return false;
            if (!Uri.TryCreate(owaUrl, UriKind.Absolute, out Uri u)) return false;
            if (u.Scheme != Uri.UriSchemeHttps) return false;
            return u.Host.EndsWith(".office365.com", StringComparison.OrdinalIgnoreCase)
                || u.Host.EndsWith(".office.com", StringComparison.OrdinalIgnoreCase);
        }

        // ── Local logging (Message-IDs only, never content) ──────────────────────
        private static void Log(string message)
        {
            try
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "GIP", "ArchiveOpen", "logs");
                Directory.CreateDirectory(dir);
                string file = Path.Combine(dir, DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ".log");
                File.AppendAllText(file,
                    DateTime.Now.ToString("o", CultureInfo.InvariantCulture) + "  " + message + Environment.NewLine);
            }
            catch { /* logging must never throw */ }
        }
    }
}
