// Send feedback to the person making Josi. The same card a crash report uses: the
// person writes a note, sees the whole report that would go with it (machine facts,
// no personal data), can change it, and chooses to send it or not.
import { useEffect, useState } from 'react';
import { useAuth } from '@/lib/auth';
import { Button, Card, CardTitle, ErrorNote } from '@/components/ui';
import { CrashReportCard } from '@/components/CrashReportCard';
import { loadCrashState, saveTesterToken, startFeedback, type PendingReport } from '@/lib/crashReports';

export function Feedback() {
  const { user } = useAuth();
  const owner = user?.role === 'super_admin';
  const [available, setAvailable] = useState<boolean | null>(null);
  const [note, setNote] = useState('');
  const [draft, setDraft] = useState<PendingReport | null>(null);
  const [done, setDone] = useState<'sent' | 'left' | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [tokenText, setTokenText] = useState('');

  useEffect(() => { if (owner) loadCrashState().then(state => setAvailable(state.settings.tokenPresent)).catch(() => setAvailable(false)); }, [owner]);

  async function saveToken() {
    setBusy(true); setError('');
    try { const result = await saveTesterToken(tokenText.trim()); setAvailable(result.settings.tokenPresent); setTokenText(''); } catch (e) { setError(e instanceof Error ? e.message : 'Could not save the token'); } finally { setBusy(false); }
  }

  async function preview() {
    setBusy(true); setError('');
    try { setDraft(await startFeedback(note)); } catch (e) { setError(e instanceof Error ? e.message : 'Could not prepare the report'); } finally { setBusy(false); }
  }

  return <div className="mx-auto grid max-w-2xl gap-4 p-4">
    <h1 className="font-display text-2xl font-semibold">Send feedback</h1>
    {!owner ? <p className="text-sm text-muted-foreground">Only the owner of this Josi can send feedback to the people making it. Tell them what you think and they can send it.</p>
      : available === false ? <Card className="space-y-3 p-4">
          <CardTitle>Paste your tester token</CardTitle>
          <p className="text-sm text-muted-foreground">Your token is on the page you landed on after signing up at heyjosi.com/beta, and in the email we sent you. It tags your feedback to you. Not signed up yet? Join the beta at heyjosi.com/beta.</p>
          <label className="grid gap-1 text-sm"><span className="font-medium">Tester token</span>
            <input className="h-10 rounded-md border border-input bg-background px-2 font-mono text-sm" value={tokenText} maxLength={200} autoComplete="off" spellCheck={false} onChange={e => setTokenText(e.target.value)} aria-label="Tester token" />
          </label>
          {error ? <ErrorNote>{error}</ErrorNote> : null}
          <Button disabled={busy || !tokenText.trim()} onClick={() => void saveToken()}>Save token</Button>
        </Card>
      : done ? <Card className="space-y-2 p-4"><CardTitle>{done === 'sent' ? 'Sent. Thank you.' : 'Not sent.'}</CardTitle><Button variant="secondary" onClick={() => { setDone(null); setDraft(null); setNote(''); }}>Write another</Button></Card>
      : draft ? <CrashReportCard pending={draft} onDone={sent => setDone(sent ? 'sent' : 'left')} />
      : <Card className="space-y-3 p-4">
          <label className="grid gap-1 text-sm"><span className="font-medium">What would you like to tell us?</span>
            <textarea className="min-h-32 rounded-md border border-input bg-background p-2 text-sm" value={note} maxLength={4000} onChange={e => setNote(e.target.value)} placeholder="What worked, what did not, what you wished it did" aria-label="Your feedback" />
          </label>
          <p className="text-xs text-muted-foreground">Next you will see everything that would be sent, and you choose whether to send it.</p>
          {error ? <ErrorNote>{error}</ErrorNote> : null}
          <Button disabled={busy || !note.trim()} onClick={() => void preview()}>See what will be sent</Button>
        </Card>}
  </div>;
}
