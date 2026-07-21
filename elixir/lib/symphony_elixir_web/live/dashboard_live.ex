defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Route-backed Symphony Studio operational workbench.

  All route state arrives through `SymphonyElixirWeb.StudioDataPort`. The
  LiveView owns presentation and proposal-bound user actions, not Linear or
  worker mutations.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, RuntimeStudioDataPort}

  @runtime_tick_ms 1_000
  @data_refresh_ms 5_000
  @intent_limit 50_000
  @preview_version "v0.2.0-buildweek-preview.1"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:data_port, data_port())
      |> assign(:page, nil)
      |> assign(:load_error, nil)
      |> assign(:action_error, nil)
      |> assign(:announcement, "")
      |> assign(:now, DateTime.utc_now())
      |> assign(:intent_input, %{"kind" => "prompt", "content" => ""})
      |> assign(:intent_error, nil)
      |> assign(:preview_version, @preview_version)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      schedule_data_refresh()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_page(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:data_refresh, socket) do
    schedule_data_refresh()
    {:noreply, refresh_current_page(socket)}
  end

  def handle_info(:observability_updated, socket) do
    {:noreply, refresh_current_page(socket)}
  end

  @impl true
  def handle_event("validate_intent", %{"intent" => attrs}, socket) do
    input = normalized_intent_input(attrs)
    {:noreply, socket |> assign(:intent_input, input) |> assign(:intent_error, validate_intent(input))}
  end

  def handle_event("submit_intent", %{"intent" => attrs}, socket) do
    input = normalized_intent_input(attrs)

    case validate_intent(input) do
      nil ->
        socket = assign(socket, :intent_input, input)

        {:noreply,
         run_command(socket, :submit_intent, input, fn socket, page ->
           if is_binary(page.intent_id) do
             push_patch(socket, to: intent_path(page.intent_id))
           else
             socket
           end
         end)}

      message ->
        {:noreply,
         socket
         |> assign(:intent_input, input)
         |> assign(:intent_error, message)
         |> announce(message)}
    end
  end

  def handle_event("answer_questions", params, socket) do
    answers = params |> Map.get("answers", %{}) |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
    run_command_reply(socket, :answer_clarifications, %{"answers" => answers})
  end

  def handle_event("use_recommended_defaults", _params, socket) do
    run_command_reply(socket, :use_recommended_defaults, %{})
  end

  def handle_event("present_proposal", _params, socket) do
    run_command_reply(socket, :present_proposal, %{})
  end

  def handle_event("approve_publication", %{"proposal_digest" => digest}, socket) do
    run_command_reply(socket, :approve_publication, %{"proposal_digest" => digest})
  end

  def handle_event("publish_approved_plan", _params, socket) do
    run_command_reply(socket, :publish_approved_plan, %{})
  end

  def handle_event("start_first_ready", _params, socket) do
    run_command_reply(socket, :start_first_ready, %{})
  end

  def handle_event("refresh_page", _params, socket) do
    {:noreply, socket |> refresh_current_page() |> announce("Current state refreshed.")}
  end

  def handle_event("copy_complete", %{"label" => label}, socket) do
    {:noreply, announce(socket, "#{label} copied.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="studio-frame" data-legacy-surface="Operations Dashboard">
      <a class="skip-link" href="#studio-main">Skip to main content</a>

      <header class="studio-topbar">
        <div class="brand-lockup">
          <.link navigate="/" class="brand-link" aria-label="Symphony Studio Mission Control">
            <span class="brand-mark" aria-hidden="true">S</span>
            <span>
              <strong>Symphony Studio</strong>
              <small>Build Week Preview</small>
            </span>
          </.link>
        </div>

        <nav class="primary-nav" aria-label="Primary navigation">
          <.nav_link href="/work/new" label="New Work" active={@live_action == :new_work} />
          <.nav_link href="/setup" label="Setup" active={@live_action == :setup} />
          <.nav_link href="/" label="Mission Control" active={@live_action == :mission_control} />
          <.nav_link
            :if={@live_action == :run_detail and @page && @page[:run]}
            href={run_path(@page.run.id)}
            label="Run Detail"
            active={true}
          />
        </nav>

        <details class="mobile-nav">
          <summary aria-label="Open navigation">Menu</summary>
          <nav aria-label="Mobile navigation">
            <.nav_link href="/work/new" label="New Work" active={@live_action == :new_work} />
            <.nav_link href="/setup" label="Setup" active={@live_action == :setup} />
            <.nav_link href="/" label="Mission Control" active={@live_action == :mission_control} />
            <.nav_link
              :if={@live_action == :run_detail and @page && @page[:run]}
              href={run_path(@page.run.id)}
              label="Run Detail"
              active={true}
            />
          </nav>
        </details>

        <div class="topbar-truth">
          <div class="connection-state" role="status" aria-live="polite">
            <span class="status-badge status-badge-live"><span aria-hidden="true">●</span> Live</span>
            <span class="status-badge status-badge-offline"><span aria-hidden="true">◇</span> Offline · reconnecting</span>
          </div>
          <span class="version-label mono">{@preview_version}</span>
        </div>
      </header>

      <p id="studio-announcer" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {@announcement}
      </p>

      <main id="studio-main" class="studio-main" tabindex="-1">
        <.error_view :if={@load_error} error={@load_error} />
        <.mission_control
          :if={!@load_error and @live_action == :mission_control and @page}
          page={@page}
          now={@now}
        />
        <.setup :if={!@load_error and @live_action == :setup and @page} page={@page} />
        <.new_work
          :if={!@load_error and @live_action == :new_work and @page}
          page={@page}
          input={@intent_input}
          input_error={@intent_error}
          action_error={@action_error}
        />
        <.run_detail
          :if={!@load_error and @live_action == :run_detail and @page}
          page={@page}
          now={@now}
        />
      </main>
    </div>
    """
  end

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:active, :boolean, default: false)

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@href} class={nav_link_class(@active)} aria-current={if(@active, do: "page")}>
      {@label}
    </.link>
    """
  end

  attr(:error, :map, required: true)

  defp error_view(assigns) do
    ~H"""
    <section class="state-panel state-panel-danger" role="alert" aria-labelledby="load-error-title">
      <p class="section-kicker">Current state unavailable</p>
      <h1 id="load-error-title">Snapshot unavailable</h1>
      <p>{@error.message}</p>
      <p class="mono error-code">{@error.code}</p>
      <button type="button" class="button secondary" phx-click="refresh_page">Try again</button>
    </section>
    """
  end

  attr(:page, :map, required: true)
  attr(:now, DateTime, required: true)

  defp mission_control(assigns) do
    assigns = assign(assigns, :other_runs, other_runs(assigns.page))

    ~H"""
    <div class="page-stack mission-page">
      <header class="page-heading compact-heading">
        <div>
          <p class="section-kicker">Runtime operations</p>
          <h1>Mission Control</h1>
        </div>
        <div class="freshness-block">
          <span>Last update</span>
          <time class="mono" datetime={@page.generated_at}>{format_timestamp(@page.generated_at)}</time>
        </div>
      </header>

      <%= if @page.active_run do %>
        <article class={active_run_class(@page.active_run.state)} aria-labelledby="active-run-title">
          <div class="active-run-main">
            <div class="object-heading">
              <div>
                <p class="object-id mono">{@page.active_run.issue_identifier}</p>
                <h2 id="active-run-title">{@page.active_run.objective}</h2>
              </div>
              <.state_badge state={@page.active_run.state} label={@page.active_run.state_label} />
            </div>

            <dl class="fact-strip">
              <div>
                <dt>Phase</dt>
                <dd>{@page.active_run.phase_label}</dd>
              </div>
              <div>
                <dt>Conductor</dt>
                <dd>{@page.active_run.conductor}</dd>
              </div>
              <div>
                <dt>Elapsed</dt>
                <dd class="numeric">{run_elapsed(@page.active_run, @now)}</dd>
              </div>
              <div :if={@page.active_run.usage}>
                <dt>Tokens used</dt>
                <dd class="numeric">{format_int(@page.active_run.usage.total_tokens)}</dd>
              </div>
            </dl>

            <div class="activity-line">
              <span class="activity-marker" aria-hidden="true"></span>
              <div>
                <span>Codex update</span>
                <strong>{@page.active_run.latest_activity}</strong>
                <time :if={@page.active_run.latest_activity_at} class="mono" datetime={@page.active_run.latest_activity_at}>
                  {format_timestamp(@page.active_run.latest_activity_at)}
                </time>
              </div>
            </div>
          </div>

          <aside class="decision-panel" aria-labelledby="next-action-title">
            <p class="section-kicker">Next action</p>
            <h3 id="next-action-title">{decision_heading(@page.active_run)}</h3>
            <p>{@page.active_run.blocker || @page.active_run.next_action}</p>
            <dl class="decision-evidence">
              <div><dt>Checks</dt><dd>{@page.active_run.check_summary}</dd></div>
              <div><dt>Review</dt><dd>{@page.active_run.review_summary}</dd></div>
            </dl>
            <div class="button-row">
              <.link class="button primary" navigate={run_path(@page.active_run.id)}>View run</.link>
              <a
                :if={@page.active_run.issue_url}
                class="button secondary"
                href={@page.active_run.issue_url}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={"Open #{@page.active_run.issue_identifier} in the issue tracker"}
              >Open in Linear</a>
              <button
                :if={@page.active_run.session_id}
                id="copy-active-session"
                type="button"
                class="button quiet"
                phx-hook="CopyText"
                data-copy-value={@page.active_run.session_id}
                data-copy-label="Session ID"
              >Copy ID</button>
            </div>
          </aside>
        </article>
      <% else %>
        <section class="state-panel" aria-labelledby="empty-runs-title">
          <p class="section-kicker">Queue clear</p>
          <h2 id="empty-runs-title">Nothing is running</h2>
          <p>No eligible, blocked, or retrying issues are present in the current runtime snapshot.</p>
          <div class="button-row">
            <.link class="button primary" navigate="/work/new">Create new work</.link>
            <.link class="button secondary" navigate="/setup">Check setup</.link>
          </div>
        </section>
      <% end %>

      <section class="runtime-summary" aria-label="Current runtime totals">
        <div><span>Active</span><strong class="numeric">{@page.counts.running}</strong></div>
        <div><span>Retrying</span><strong class="numeric">{@page.counts.retrying}</strong></div>
        <div><span>Blocked</span><strong class="numeric">{@page.counts.blocked}</strong></div>
        <div :if={@page.usage}>
          <span>Total tokens</span><strong class="numeric">{format_int(@page.usage.total_tokens)}</strong>
        </div>
        <div :if={!@page.usage}><span>Usage</span><strong>Not reported</strong></div>
      </section>

      <section :if={@other_runs != []} class="section-block" aria-labelledby="queue-title">
        <div class="section-heading">
          <div><p class="section-kicker">Queue and attention</p><h2 id="queue-title">Other runtime work</h2></div>
          <span class="count-label numeric">{length(@other_runs)} runs</span>
        </div>
        <div class="run-list">
          <article :for={run <- @other_runs} class="run-row">
            <div class="run-row-identity">
              <span class="object-id mono">{run.issue_identifier}</span>
              <strong>{run.objective}</strong>
            </div>
            <.state_badge state={run.state} label={run.state_label} />
            <div><span class="row-label">Phase</span><strong>{run.phase_label}</strong></div>
            <div><span class="row-label">Latest</span><strong>{run.latest_activity}</strong></div>
            <div><span class="row-label">Next</span><strong>{run.blocker || run.next_action}</strong></div>
            <div class="run-row-actions">
              <.link class="text-link" navigate={run_path(run.id)}>View run <span aria-hidden="true">→</span></.link>
              <a
                :if={run.issue_url}
                class="text-link"
                href={run.issue_url}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={"Open #{run.issue_identifier} in the issue tracker"}
              >Linear <span aria-hidden="true">↗</span></a>
            </div>
          </article>
        </div>
      </section>

      <details :if={@page.rate_limits} class="technical-disclosure">
        <summary>Provider limit details</summary>
        <p>Provider data is present in the original runtime snapshot. Limits are not estimated or converted into completion progress.</p>
      </details>
    </div>
    """
  end

  attr(:page, :map, required: true)

  defp setup(assigns) do
    ~H"""
    <div class="page-stack setup-page">
      <header class="page-heading">
        <div>
          <p class="section-kicker">Preflight truth</p>
          <h1>Setup</h1>
        </div>
        <button type="button" class="button secondary" phx-click="refresh_page">Check again</button>
      </header>

      <section class={setup_verdict_class(@page.verdict)} aria-labelledby="readiness-title">
        <div class="verdict-symbol" aria-hidden="true">{if(@page.verdict == :ready, do: "✓", else: "!")}</div>
        <div>
          <p class="section-kicker">Readiness verdict</p>
          <h2 id="readiness-title">{@page.verdict_label}</h2>
          <p>{@page.reason}</p>
        </div>
        <dl>
          <div><dt>Checked</dt><dd class="mono">{format_timestamp(@page.checked_at)}</dd></div>
          <div><dt>Current revision</dt><dd class="mono">{short_value(@page.current_revision)}</dd></div>
          <div><dt>Evidence revision</dt><dd class="mono">{short_value(@page.source_revision)}</dd></div>
        </dl>
      </section>

      <section class="section-block" aria-labelledby="readiness-checks-title">
        <div class="section-heading">
          <div><p class="section-kicker">Required systems</p><h2 id="readiness-checks-title">Golden-path readiness</h2></div>
        </div>
        <div class="readiness-table" role="table" aria-label="Setup readiness checks">
          <div class="readiness-row readiness-header" role="row">
            <span role="columnheader">System</span>
            <span role="columnheader">State</span>
            <span role="columnheader">Checked value</span>
            <span role="columnheader">Recovery</span>
          </div>
          <article :for={row <- @page.rows} class="readiness-row" role="row">
            <div role="cell"><strong>{row.system}</strong><span>{row.label}</span></div>
            <div role="cell"><.state_badge state={row.state} label={row.state_label} /></div>
            <div role="cell"><strong class="mono">{row.value}</strong><span>{format_timestamp(row.checked_at)}</span></div>
            <div role="cell"><span>{row.remediation}</span></div>
          </article>
        </div>
      </section>

      <aside class="security-note" aria-label="Protected setup data">
        <strong>Credentials stay private.</strong>
        <span>This page reports capability and binding results only. It never renders keys, account email, credential paths, or raw Linear responses.</span>
      </aside>
    </div>
    """
  end

  attr(:page, :map, required: true)
  attr(:input, :map, required: true)
  attr(:input_error, :string, default: nil)
  attr(:action_error, :map, default: nil)

  defp new_work(assigns) do
    assigns =
      assigns
      |> assign(:stage, intent_stage(assigns.page))
      |> assign(:can_submit, assigns.page.service == :available)

    ~H"""
    <div class="page-stack new-work-page">
      <header class="page-heading compact-heading">
        <div>
          <p class="section-kicker">Intent to admission</p>
          <h1>New Work</h1>
        </div>
        <div class="intent-state">
          <span>Current state</span>
          <strong>{humanize_state(@page.lifecycle_state)}</strong>
        </div>
      </header>

      <ol class="stage-rail" aria-label="New Work stages">
        <li :for={{label, index} <- Enum.with_index(intent_stages())} class={stage_class(index, @stage)}>
          <span aria-hidden="true">{index + 1}</span><strong>{label}</strong>
        </li>
      </ol>

      <section :if={@page.service == :unavailable} class="inline-alert danger" role="alert">
        <strong>Planning is unavailable</strong>
        <span>The canonical Intent Service is not installed in this build. No Linear mutation can be requested.</span>
      </section>

      <section :if={@action_error} class={action_error_class(@action_error)} role="alert">
        <div><strong>{@action_error.message}</strong><span class="mono">{@action_error.code}</span></div>
        <button type="button" class="button quiet" phx-click="refresh_page">Reconcile state</button>
      </section>

      <section class="intent-workbench" aria-labelledby="intent-input-title">
        <div class="intent-primary">
          <div class="section-heading">
            <div><p class="section-kicker">1 · Define intent</p><h2 id="intent-input-title">What should Symphony build?</h2></div>
          </div>
          <form phx-change="validate_intent" phx-submit="submit_intent" class="intent-form">
            <div class="field-row">
              <label class="field compact-field">
                <span>Input format</span>
                <select name="intent[kind]">
                  <option value="prompt" selected={@input["kind"] == "prompt"}>Prompt</option>
                  <option value="markdown" selected={@input["kind"] == "markdown"}>Markdown specification</option>
                </select>
              </label>
              <span class="character-count mono">{String.length(@input["content"])} / 50,000</span>
            </div>
            <label class="field">
              <span>Work request</span>
              <textarea
                name="intent[content]"
                rows="10"
                maxlength="50000"
                placeholder="Describe the objective, constraints, and what evidence should prove completion."
                aria-describedby="intent-help intent-error"
              >{@input["content"]}</textarea>
            </label>
            <p id="intent-help" class="field-help">Repository inspection is read-only. A proposal appears before any Linear write.</p>
            <p :if={@input_error} id="intent-error" class="field-error" role="alert">{@input_error}</p>
            <button
              type="submit"
              class="button primary"
              disabled={!@can_submit}
              phx-disable-with="Inspecting repository…"
            >Inspect and plan</button>
          </form>
        </div>

        <aside class="inspection-panel" aria-labelledby="inspection-title">
          <p class="section-kicker">Repository truth</p>
          <h2 id="inspection-title">{@page.project.label}</h2>
          <%= if @page.inspection do %>
            <dl class="inspection-facts">
              <div><dt>Files inspected</dt><dd class="numeric">{@page.inspection.file_count || "Unavailable"}</dd></div>
              <div><dt>Test files</dt><dd class="numeric">{@page.inspection.test_file_count || "Unavailable"}</dd></div>
              <div><dt>Inspection digest</dt><dd class="mono">{short_value(@page.inspection.digest)}</dd></div>
            </dl>
            <details :if={@page.inspection.spec_paths != [] or @page.inspection.architecture_paths != []}>
              <summary>Inspected specifications</summary>
              <ul class="plain-list mono">
                <li :for={path <- @page.inspection.spec_paths ++ @page.inspection.architecture_paths}>{path}</li>
              </ul>
            </details>
          <% else %>
            <p>Inspection facts appear here after the canonical service attaches this repository.</p>
          <% end %>
          <div class="binding-line">
            <span>Linear target</span>
            <strong>Exact dedicated project · Backlog</strong>
          </div>
        </aside>
      </section>

      <section
        :if={@page.clarifications.status == "required" and @page.clarifications.questions != []}
        class="section-block decision-section"
        aria-labelledby="questions-title"
      >
        <div class="section-heading">
          <div><p class="section-kicker">2 · Clarify</p><h2 id="questions-title">Material questions</h2></div>
          <span class="count-label">{length(@page.clarifications.questions)} of 2 maximum</span>
        </div>
        <form phx-submit="answer_questions" class="questions-form">
          <fieldset :for={{question, index} <- Enum.with_index(@page.clarifications.questions)}>
            <legend><span class="mono">Q{index + 1}</span> {question.prompt}</legend>
            <p :if={question.impact}>{question.impact}</p>
            <label class="field">
              <span>Your answer</span>
              <textarea name={"answers[#{question.id}]"} rows="3" required>{Map.get(@page.clarifications.answers, question.id, "")}</textarea>
            </label>
            <p :if={question.recommended_answer} class="recommended-answer">
              <strong>Recommended:</strong> {question.recommended_answer}
            </p>
          </fieldset>
          <div class="button-row">
            <button type="submit" class="button primary" phx-disable-with="Saving answers…">Use these answers</button>
            <button type="button" class="button secondary" phx-click="use_recommended_defaults" phx-disable-with="Applying defaults…">
              Use recommended defaults
            </button>
          </div>
        </form>
      </section>

      <.proposal :if={@page.proposal} page={@page} />
      <.publication :if={not is_nil(@page.proposal) and publication_visible?(@page)} page={@page} />
    </div>
    """
  end

  attr(:page, :map, required: true)

  defp proposal(assigns) do
    ~H"""
    <section class="section-block proposal-section" aria-labelledby="proposal-title">
      <div class="section-heading">
        <div><p class="section-kicker">3 · Review proposal</p><h2 id="proposal-title">{@page.proposal.tasks |> length()} proposed tasks</h2></div>
        <span class="digest-label mono">{short_value(@page.proposal.digest)}</span>
      </div>

      <div class="proposal-list">
        <article :for={task <- @page.proposal.tasks} class="proposal-task">
          <div class="task-position mono">{task.position || "–"}</div>
          <div>
            <h3>{task.title}</h3>
            <p>{task.description}</p>
            <ul class="criteria-list">
              <li :for={criterion <- task.acceptance_criteria}>{criterion}</li>
            </ul>
            <p :if={task.depends_on != []} class="dependency-line">
              <span>Depends on</span> <span class="mono">{Enum.join(task.depends_on, ", ")}</span>
            </p>
          </div>
        </article>
      </div>

      <div class="mutation-boundary">
        <div>
          <strong>No Linear mutation has occurred.</strong>
          <span>This proposal is bound to digest <span class="mono">{short_value(@page.proposal.digest)}</span>.</span>
        </div>
        <button
          :if={@page.proposal.status == "proposed"}
          type="button"
          class="button primary"
          phx-click="present_proposal"
          phx-disable-with="Binding proposal…"
        >Review final proposal</button>
        <form :if={@page.proposal.status == "presented"} phx-submit="approve_publication">
          <input type="hidden" name="proposal_digest" value={@page.proposal.digest} />
          <button type="submit" class="button primary" phx-disable-with="Recording approval…">
            Approve Backlog publication
          </button>
        </form>
        <span :if={@page.proposal.status == "approved"} class="approval-receipt">✓ Proposal-bound approval recorded</span>
      </div>
    </section>
    """
  end

  attr(:page, :map, required: true)

  defp publication(assigns) do
    ~H"""
    <section class="section-block publication-section" aria-labelledby="publication-title">
      <div class="section-heading">
        <div><p class="section-kicker">4 · Publish and start</p><h2 id="publication-title">Linear publication</h2></div>
        <.state_badge state={publication_tone(@page.publication.status)} label={humanize_state(@page.publication.status)} />
      </div>

      <div class="effect-statement">
        <strong>External effect</strong>
        <span>Publish only this approved proposal to the dedicated Linear project's Backlog. Starting work remains separate.</span>
      </div>

      <button
        :if={@page.proposal.status == "approved" and @page.publication.status in ["not_started", "blocked"]}
        type="button"
        class="button primary"
        phx-click="publish_approved_plan"
        phx-disable-with="Publishing once…"
      >Publish approved tasks</button>

      <div :if={@page.publication.status == "in_progress"} class="inline-alert info" role="status">
        <strong>Publication in progress</strong><span>Duplicate activation is disabled while Linear confirms each issue.</span>
      </div>

      <div :if={@page.publication.last_error} class="inline-alert danger" role="alert">
        <strong>{@page.publication.last_error.message}</strong><span class="mono">{@page.publication.last_error.code}</span>
      </div>

      <div :if={@page.publication.tasks != []} class="publication-list">
        <div :for={task <- @page.publication.tasks} class="publication-row">
          <span class="mono">{task.task_id}</span>
          <strong>{humanize_state(task.status)}</strong>
          <span class="mono">{task.issue_identifier || "Awaiting confirmation"}</span>
          <span :if={Map.get(task, :last_error)} class="publication-task-error" role="alert">
            {get_in(task, [:last_error, :message])} · <span class="mono">{get_in(task, [:last_error, :code])}</span>
          </span>
        </div>
      </div>

      <div :for={relation <- Map.get(@page.publication, :relation_entries, [])} :if={relation.last_error} class="publication-task-error relation-error" role="alert">
        Relation {relation.prerequisite_task_id} → {relation.dependent_task_id}: {relation.last_error.message}
        <span class="mono">{relation.last_error.code}</span>
      </div>

      <div :if={@page.publication.status in ["partial", "uncertain"]} class="reconciliation-state" role="alert">
        <strong>{if(@page.publication.status == "partial", do: "Partially published", else: "Publication result uncertain")}</strong>
        <span>Do not retry blindly. Reconcile the recorded idempotency keys with Linear, then refresh this intent.</span>
        <button type="button" class="button secondary" phx-click="refresh_page">Reconcile now</button>
      </div>

      <div :if={@page.publication.status == "complete"} class="start-boundary">
        <div>
          <strong>Backlog publication confirmed</strong>
          <span>Starting the first dependency-ready task is a separate external action.</span>
        </div>
        <button
          :if={@page.start.status in ["not_started", "blocked"]}
          type="button"
          class="button primary"
          phx-click="start_first_ready"
          phx-disable-with="Requesting Todo transition…"
        >Start first ready task</button>
      </div>

      <div :if={Map.get(@page.start, :last_error)} class="inline-alert danger" role="alert">
        <strong>{get_in(@page.start, [:last_error, :message])}</strong><span class="mono">{get_in(@page.start, [:last_error, :code])}</span>
      </div>

      <div :if={@page.start.status in ["uncertain", "waiting_for_admission", "admitted"]} class="admission-state" role="status">
        <.state_badge state={publication_tone(@page.start.status)} label={humanize_state(@page.start.status)} />
        <div>
          <strong>{start_heading(@page.start.status)}</strong>
          <span>{start_copy(@page.start)}</span>
        </div>
        <.link :if={@page.admission && @page.admission.run_id} class="button secondary" navigate={run_path(@page.admission.run_id)}>
          Open admitted run
        </.link>
      </div>
    </section>
    """
  end

  attr(:page, :map, required: true)
  attr(:now, DateTime, required: true)

  defp run_detail(assigns) do
    assigns = assign(assigns, :terminal, terminal_run?(assigns.page))

    ~H"""
    <div class="page-stack run-detail-page">
      <header class="run-header">
        <div>
          <.link class="back-link" navigate="/">← Mission Control</.link>
          <p class="object-id mono">{@page.run.issue_identifier}</p>
          <h1>{@page.run.objective}</h1>
        </div>
        <div class="run-header-state">
          <.state_badge state={@page.run.state} label={@page.run.state_label} />
          <dl>
            <div><dt>Phase</dt><dd>{@page.run.phase_label}</dd></div>
            <div><dt>Conductor</dt><dd>{@page.run.conductor}</dd></div>
            <div><dt>Elapsed</dt><dd class="numeric">{run_elapsed(@page.run, @now)}</dd></div>
            <div><dt>Updated</dt><dd class="mono">{format_timestamp(@page.generated_at)}</dd></div>
          </dl>
        </div>
      </header>

      <section class={decision_banner_class(@page.run.state)} aria-labelledby="run-next-action">
        <div><p class="section-kicker">{if(@page.run.blocker, do: "Blocker", else: "Next action")}</p><h2 id="run-next-action">{decision_heading(@page.run)}</h2></div>
        <p>{@page.run.blocker || @page.run.next_action}</p>
        <div class="button-row">
          <a
            :if={@page.run.issue_url}
            class="button secondary"
            href={@page.run.issue_url}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={"Open #{@page.run.issue_identifier} in the issue tracker"}
          >Open in Linear</a>
          <button
            :if={@page.run.session_id}
            id="copy-run-session"
            type="button"
            class="button quiet"
            phx-hook="CopyText"
            data-copy-value={@page.run.session_id}
            data-copy-label="Session ID"
          >Copy ID</button>
        </div>
      </section>

      <.outcome_section :if={@terminal} page={@page} />

      <nav class="phase-rail" aria-label="Run phases">
        <ol>
          <li :for={phase <- @page.run.phase_rail} class={phase_status_class(phase.status)} aria-current={if(phase.status == :active, do: "step")}>
            <span class="phase-mark" aria-hidden="true">{phase_symbol(phase.status)}</span>
            <span><strong>{phase.label}</strong><small>{humanize_state(phase.status)}</small></span>
          </li>
        </ol>
      </nav>

      <div class="run-content-grid">
        <div class="run-evidence-column">
          <section class="section-block" aria-labelledby="objective-title">
            <div class="section-heading"><div><p class="section-kicker">Contract</p><h2 id="objective-title">Objective</h2></div></div>
            <p class="lead-copy">{@page.run.objective}</p>
            <h3>Acceptance criteria</h3>
            <ul :if={@page.acceptance_criteria != []} class="criteria-list">
              <li :for={criterion <- @page.acceptance_criteria}>{criterion}</li>
            </ul>
            <p :if={@page.acceptance_criteria == []} class="unavailable-copy">Not recorded by the current runtime projection.</p>
          </section>

          <section class="section-block" aria-labelledby="plan-title">
            <div class="section-heading"><div><p class="section-kicker">Execution</p><h2 id="plan-title">Plan</h2></div></div>
            <ol :if={@page.plan != []} class="plan-list">
              <li :for={step <- @page.plan} class={plan_step_class(step)}>
                <span aria-hidden="true">{plan_step_symbol(step)}</span><div><strong>{step[:label] || step[:title]}</strong><small>{humanize_state(step[:status] || :pending)}</small></div>
              </li>
            </ol>
            <p :if={@page.plan == []} class="unavailable-copy">No structured plan is available. Future steps are not inferred.</p>
          </section>

          <section class="section-block" aria-labelledby="activity-title">
            <div class="section-heading"><div><p class="section-kicker">Meaningful events</p><h2 id="activity-title">Activity</h2></div></div>
            <div :if={@page.activity != []} class="activity-list">
              <details :for={event <- @page.activity} class="activity-event" open={event.result in [:blocked, :failed]}>
                <summary>
                  <span class="activity-marker" aria-hidden="true"></span>
                  <span><strong>{event.label}</strong><small>{event.summary}</small></span>
                  <time class="mono" datetime={event.occurred_at}>{format_timestamp(event.occurred_at)}</time>
                </summary>
                <dl>
                  <div><dt>Phase</dt><dd>{humanize_state(event.phase)}</dd></div>
                  <div><dt>Result</dt><dd>{humanize_state(event.result)}</dd></div>
                  <div><dt>Effect</dt><dd>{humanize_state(event.effect)}</dd></div>
                </dl>
              </details>
            </div>
            <p :if={@page.activity == []} class="unavailable-copy">No meaningful activity has been reported.</p>
          </section>

          <section class="section-block" aria-labelledby="changes-title">
            <div class="section-heading"><div><p class="section-kicker">Repository</p><h2 id="changes-title">Changes</h2></div></div>
            <div :if={@page.changes != []} class="file-list">
              <div :for={change <- @page.changes} class="file-row"><code>{change.path}</code><span>{change.summary}</span><strong>{humanize_state(change.status)}</strong></div>
            </div>
            <p :if={@page.changes == []} class="unavailable-copy">No changed-file records are available. A draft is not presented as a commit.</p>
          </section>
        </div>

        <aside class="run-proof-column">
          <section class="section-block" aria-labelledby="checks-title">
            <div class="section-heading"><div><p class="section-kicker">Deterministic</p><h2 id="checks-title">Checks</h2></div></div>
            <div :if={@page.checks != []} class="check-list">
              <article :for={check <- @page.checks} class="check-row">
                <.state_badge state={check.status} label={humanize_state(check.status)} />
                <div><code>{check.command}</code><span>{check.summary}</span></div>
                <time class="mono" datetime={check.completed_at}>{format_timestamp(check.completed_at)}</time>
              </article>
            </div>
            <p :if={@page.checks == []} class="unavailable-copy">Not run or unavailable. No passing result is inferred.</p>
          </section>

          <section class="section-block" aria-labelledby="review-title">
            <div class="section-heading"><div><p class="section-kicker">Quality lane</p><h2 id="review-title">Independent review</h2></div><.state_badge state={@page.review.status} label={humanize_state(@page.review.status)} /></div>
            <dl class="review-meta">
              <div><dt>Role</dt><dd>Independent review role</dd></div>
              <div><dt>Source</dt><dd class="mono">{short_value(@page.review.source_revision)}</dd></div>
              <div><dt>Completed</dt><dd class="mono">{format_timestamp(@page.review.completed_at)}</dd></div>
            </dl>
            <div :if={@page.review.findings != []} class="finding-list">
              <article :for={finding <- @page.review.findings} class="finding-row">
                <strong>{finding.severity}</strong><div><span>{finding.title}</span><small>{finding.disposition}</small></div>
              </article>
            </div>
            <p :if={@page.review.findings == [] and @page.review.status in [:not_run, :blocked]} class="unavailable-copy">
              Review is {humanize_state(@page.review.status)}. Completion remains unavailable.
            </p>
          </section>
        </aside>
      </div>

      <.outcome_section :if={!@terminal} page={@page} />
    </div>
    """
  end

  attr(:page, :map, required: true)

  defp outcome_section(assigns) do
    ~H"""
    <section class={outcome_class(@page.outcome.status)} aria-labelledby="outcome-title">
      <div class="outcome-verdict">
        <span aria-hidden="true">{if(@page.outcome.status == :complete, do: "✓", else: "!")}</span>
        <div><p class="section-kicker">Evidence and outcome</p><h2 id="outcome-title">{humanize_state(@page.outcome.status)}</h2></div>
      </div>
      <p class="outcome-reason">{@page.outcome.reason}</p>
      <div :if={@page.evidence != []} class="evidence-list">
        <div :for={evidence <- @page.evidence} class="evidence-row">
          <div><strong>{evidence.label}</strong><span>{evidence.summary}</span></div>
          <code>{evidence.reference}</code>
          <button
            id={"copy-evidence-#{evidence_id(evidence)}"}
            type="button"
            class="button quiet"
            phx-hook="CopyText"
            data-copy-value={evidence.reference}
            data-copy-label={evidence.label}
          >Copy</button>
        </div>
      </div>
      <p :if={@page.evidence == []} class="unavailable-copy">No durable evidence references are available.</p>
    </section>
    """
  end

  attr(:state, :any, required: true)
  attr(:label, :string, required: true)

  defp state_badge(assigns) do
    ~H"""
    <span class={state_badge_class(@state)}><span aria-hidden="true">{state_symbol(@state)}</span> {@label}</span>
    """
  end

  defp load_page(socket, action, params) do
    case socket.assigns.data_port.load(action, params) do
      {:ok, page} ->
        socket
        |> assign(:page, page)
        |> assign(:load_error, nil)
        |> assign(:action_error, nil)

      {:error, error} ->
        socket
        |> assign(:page, nil)
        |> assign(:load_error, error)
    end
  end

  defp refresh_current_page(%{assigns: %{live_action: :new_work, page: %{intent_id: intent_id}}} = socket)
       when is_binary(intent_id) do
    load_page(socket, :new_work, %{"intent" => intent_id})
  end

  defp refresh_current_page(%{assigns: %{live_action: :run_detail, page: %{run: %{id: run_id}}}} = socket) do
    load_page(socket, :run_detail, %{"run_id" => run_id})
  end

  defp refresh_current_page(%{assigns: %{live_action: action}} = socket) do
    load_page(socket, action, %{})
  end

  defp run_command_reply(socket, command, payload) do
    {:noreply, run_command(socket, command, payload, fn socket, _page -> socket end)}
  end

  defp run_command(socket, command, payload, after_success) do
    context = %{
      command_id: command_id(command, payload, socket.assigns.page),
      intent_id: socket.assigns.page && socket.assigns.page[:intent_id],
      proposal_digest: get_in(socket.assigns, [:page, :proposal, :digest])
    }

    case socket.assigns.data_port.command(command, payload, context) do
      {:ok, page} ->
        socket
        |> assign(:page, page)
        |> assign(:load_error, nil)
        |> assign(:action_error, nil)
        |> announce(command_success(command, page))
        |> after_success.(page)

      {:error, error} ->
        socket
        |> assign(:action_error, Map.put(error, :uncertain, false))
        |> announce(error.message)

      {:uncertain, error} ->
        socket
        |> assign(:action_error, Map.put(error, :uncertain, true))
        |> announce("External result uncertain. Reconcile before retrying.")
    end
  end

  defp command_id(command, payload, page) do
    basis = %{
      command: command,
      intent_id: page && page[:intent_id],
      proposal_digest: page && page[:proposal] && page.proposal[:digest],
      payload: payload
    }

    digest = :crypto.hash(:sha256, Jason.encode!(basis)) |> Base.url_encode64(padding: false)
    "studio-web-#{binary_part(digest, 0, 24)}"
  end

  defp command_success(:submit_intent, _page), do: "Repository inspected. Intent state updated."
  defp command_success(:answer_clarifications, _page), do: "Clarifications recorded."
  defp command_success(:use_recommended_defaults, _page), do: "Recommended answers recorded."
  defp command_success(:present_proposal, _page), do: "Proposal is ready for publication approval."
  defp command_success(:approve_publication, _page), do: "Proposal-bound publication approval recorded."
  defp command_success(:publish_approved_plan, _page), do: "Publication state updated from Linear receipts."
  defp command_success(:start_first_ready, _page), do: "Start state updated. Await runtime admission before treating work as queued."
  defp command_success(_command, _page), do: "Current state updated."

  defp normalized_intent_input(attrs) do
    %{
      "kind" => if(attrs["kind"] in ["prompt", "markdown"], do: attrs["kind"], else: "prompt"),
      "content" => attrs |> Map.get("content", "") |> to_string()
    }
  end

  defp validate_intent(%{"content" => content}) do
    length = String.length(String.trim(content))

    cond do
      length == 0 -> "Enter a work request before inspection."
      length > @intent_limit -> "Work request must be #{@intent_limit} characters or fewer."
      true -> nil
    end
  end

  defp data_port, do: Endpoint.config(:studio_data_port) || RuntimeStudioDataPort

  defp announce(socket, message) do
    assign(socket, :announcement, message || "")
  end

  defp nav_link_class(true), do: "nav-link current"
  defp nav_link_class(false), do: "nav-link"

  defp active_run_class(state), do: "active-run state-#{css_state(state)}"
  defp setup_verdict_class(:ready), do: "setup-verdict ready"
  defp setup_verdict_class(_verdict), do: "setup-verdict not-ready"
  defp decision_banner_class(state), do: "decision-banner state-#{css_state(state)}"
  defp outcome_class(:complete), do: "outcome-section complete"
  defp outcome_class(_status), do: "outcome-section incomplete"

  defp state_badge_class(state), do: "state-badge tone-#{state_tone(state)}"

  defp state_tone(state) when state in [:active, :passed, :pass, :complete, :completed, :ready, :admitted], do: "success"
  defp state_tone(state) when state in [:queued, :pending, :warning, :validating, :reviewing, :checking, :not_run], do: "warning"
  defp state_tone(state) when state in [:blocked, :failed, :fail, :incomplete, :error], do: "danger"
  defp state_tone(_state), do: "neutral"

  defp state_symbol(state) when state in [:active, :passed, :pass, :complete, :completed, :ready, :admitted], do: "●"
  defp state_symbol(state) when state in [:blocked, :failed, :fail, :incomplete, :error], do: "!"
  defp state_symbol(state) when state in [:queued, :pending, :warning, :validating, :reviewing, :checking], do: "◆"
  defp state_symbol(_state), do: "○"

  defp css_state(state), do: state |> to_string() |> String.replace("_", "-")

  defp action_error_class(%{uncertain: true}), do: "action-alert uncertain"
  defp action_error_class(_error), do: "action-alert danger"

  defp other_runs(%{runs: runs, active_run: nil}), do: runs
  defp other_runs(%{runs: runs, active_run: active}), do: Enum.reject(runs, &(&1.id == active.id))

  defp decision_heading(%{blocker: blocker}) when is_binary(blocker), do: "Resolve blocker"
  defp decision_heading(%{state: :completed}), do: "Inspect verified outcome"
  defp decision_heading(%{state: :incomplete}), do: "Review incomplete evidence"
  defp decision_heading(_run), do: "Continue from current phase"

  defp run_elapsed(%{elapsed_label: label}, _now) when is_binary(label) and label != "", do: label

  defp run_elapsed(%{started_at: started_at}, now) when not is_nil(started_at) do
    case parse_datetime(started_at) do
      %DateTime{} = started -> format_duration(DateTime.diff(now, started, :second))
      _ -> "Unavailable"
    end
  end

  defp run_elapsed(_run, _now), do: "Unavailable"

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp format_duration(seconds) when is_integer(seconds) do
    seconds = max(seconds, 0)
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    secs = rem(seconds, 60)

    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m #{secs}s"
  end

  defp format_timestamp(nil), do: "Unavailable"

  defp format_timestamp(value) do
    case parse_datetime(value) do
      %DateTime{} = datetime -> Calendar.strftime(datetime, "%H:%M:%S UTC")
      _ -> to_string(value)
    end
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "Unavailable"

  defp short_value(value) when is_binary(value) do
    case String.split(value, "+changes", parts: 2) do
      [head, _changes] when byte_size(head) > 12 -> "#{binary_part(head, 0, 12)}… + changes"
      [head] when byte_size(head) > 12 -> "#{binary_part(head, 0, 12)}…"
      [head] when head != "" -> head
      _ -> "Unavailable"
    end
  end

  defp short_value(_value), do: "Unavailable"

  defp intent_path(intent_id), do: "/work/new?intent=#{URI.encode_www_form(intent_id)}"
  defp run_path(run_id), do: "/runs/#{URI.encode_www_form(to_string(run_id))}"

  defp intent_stages, do: ["Intent", "Clarify", "Proposal", "Publish", "Admission"]

  defp intent_stage(%{admission: admission}) when is_map(admission), do: 4
  defp intent_stage(%{start: %{status: status}}) when status in ["waiting_for_admission", "admitted", "uncertain"], do: 4
  defp intent_stage(%{publication: %{status: status}}) when status in ["in_progress", "partial", "uncertain", "complete"], do: 3
  defp intent_stage(%{proposal: proposal}) when is_map(proposal), do: 2
  defp intent_stage(%{clarifications: %{status: "required"}}), do: 1
  defp intent_stage(_page), do: 0

  defp stage_class(index, current) when index < current, do: "stage complete"
  defp stage_class(index, current) when index == current, do: "stage current"
  defp stage_class(_index, _current), do: "stage pending"

  defp publication_visible?(page) do
    page.proposal.status in ["approved"] or page.publication.status != "not_started"
  end

  defp publication_tone(status) when status in ["complete", "admitted"], do: :completed
  defp publication_tone(status) when status in ["partial", "uncertain", "blocked"], do: :blocked
  defp publication_tone(status) when status in ["in_progress", "waiting_for_admission"], do: :queued
  defp publication_tone(_status), do: :pending

  defp start_heading("admitted"), do: "Runtime admission confirmed"
  defp start_heading("waiting_for_admission"), do: "Waiting for Symphony admission"
  defp start_heading("uncertain"), do: "Start result uncertain"
  defp start_heading(_status), do: "Start state updated"

  defp start_copy(%{status: "admitted", issue_identifier: identifier}),
    do: "#{identifier || "The issue"} has a confirmed runtime admission event."

  defp start_copy(%{status: "waiting_for_admission", issue_identifier: identifier}),
    do: "#{identifier || "The issue"} is in Todo, but no Symphony admission event has been observed."

  defp start_copy(%{status: "uncertain"}),
    do: "Reconcile the Linear transition before sending another Start command."

  defp start_copy(start), do: start.confirmation || "No admission receipt is available."

  defp humanize_state(nil), do: "Unavailable"

  defp humanize_state(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp terminal_run?(%{outcome: %{status: status}}), do: status in [:complete, :incomplete]

  defp phase_status_class(status), do: "phase phase-#{css_state(status)}"
  defp phase_symbol(:passed), do: "✓"
  defp phase_symbol(:active), do: "●"
  defp phase_symbol(:blocked), do: "!"
  defp phase_symbol(:failed), do: "×"
  defp phase_symbol(_status), do: "○"

  defp plan_step_class(step), do: "plan-step state-#{css_state(step[:status] || :pending)}"
  defp plan_step_symbol(%{status: :completed}), do: "✓"
  defp plan_step_symbol(%{status: :active}), do: "●"
  defp plan_step_symbol(%{status: :blocked}), do: "!"
  defp plan_step_symbol(_step), do: "○"

  defp evidence_id(evidence) do
    evidence
    |> Map.get(:reference, "evidence")
    |> :crypto.hash(:sha256)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 8)
  end

  defp schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  defp schedule_data_refresh, do: Process.send_after(self(), :data_refresh, @data_refresh_ms)
end
