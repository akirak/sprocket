import gleam/io
import gleam/list
import gleam/result
import gleam/dynamic.{type Dynamic}
import gleam/dict.{type Dict}
import gleam/function.{identity}
import gleam/otp/actor.{type StartError, Spec}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import ids/cuid
import sprocket/internal/logger
import sprocket/internal/constants.{call_timeout}
import sprocket/context.{
  type ComponentHooks, type Context, type Dispatcher, type EffectCleanup,
  type EffectResult, type Element, type Hook, type HookDependencies,
  type IdentifiableHandler, type Updater, Callback, Changed, Client, Context,
  Dispatcher, Effect, EffectResult, Handler, IdentifiableHandler, Memo, Reducer,
  Unchanged, Updater, callback_param_from_string, compare_deps,
}
import sprocket/internal/reconcile.{
  type ReconciledElement, ReconciledComponent, ReconciledElement,
  ReconciledFragment, ReconciledResult,
}
import sprocket/internal/reconcilers/recursive
import sprocket/internal/patch.{type Patch}
import sprocket/internal/utils/ordered_map.{
  type KeyedItem, type OrderedMapIter, KeyedItem,
}
import sprocket/internal/utils/unique.{type Unique}
import sprocket/internal/exceptions.{throw_on_unexpected_hook_result}
import sprocket/internal/utils/timer

pub type Runtime =
  Subject(Message)

pub type RenderedUpdate {
  FullUpdate(ReconciledElement)
  PatchUpdate(patch: Patch)
}

pub opaque type State {
  State(
    ctx: Context,
    updater: Updater(RenderedUpdate),
    reconciled: Option(ReconciledElement),
    cuid_channel: Subject(cuid.Message),
  )
}

// TODO: it would be nice to be able to make this type private. But the get_state function needs to be
// public in order to be used in the tests and therefore this type needs to be public as well.
pub opaque type Message {
  Shutdown
  GetReconciled(reply_with: Subject(Option(ReconciledElement)))
  ProcessEvent(id: String, payload: Option(String))
  ProcessEventImmediate(
    reply_with: Subject(Result(Nil, Nil)),
    id: String,
    payload: Option(String),
  )
  ProcessClientHook(
    id: String,
    event: String,
    payload: Option(Dynamic),
    reply_dispatcher: fn(String, Option(String)) -> Result(Nil, Nil),
  )
  UpdateHookState(Unique, fn(Hook) -> Hook)
  ReconcileImmediate(reply_with: Subject(ReconciledElement))
  RenderUpdate
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Shutdown -> {
      case state.reconciled {
        Some(reconciled) -> {
          cleanup_hooks(reconciled)
          Nil
        }
        _ -> Nil
      }

      actor.Stop(process.Normal)
    }

    GetReconciled(reply_with) -> {
      actor.send(reply_with, state.reconciled)

      actor.continue(state)
    }

    ProcessEvent(id, payload) -> {
      let handler =
        list.find(state.ctx.handlers, fn(h) {
          let IdentifiableHandler(i, _) = h
          unique.to_string(i) == id
        })

      case handler {
        Ok(context.IdentifiableHandler(_, handler_fn)) -> {
          // call the event handler function
          payload
          |> option.map(callback_param_from_string)
          |> handler_fn()

          actor.continue(state)
        }
        _ -> {
          logger.error("No handler found with id: " <> id)

          actor.continue(state)
        }
      }
    }

    ProcessEventImmediate(reply_with, id, payload) -> {
      let handler =
        list.find(state.ctx.handlers, fn(h) {
          let IdentifiableHandler(i, _) = h
          unique.to_string(i) == id
        })

      case handler {
        Ok(context.IdentifiableHandler(_, handler_fn)) -> {
          // call the event handler function
          payload
          |> option.map(callback_param_from_string)
          |> handler_fn()

          actor.send(reply_with, Ok(Nil))

          actor.continue(state)
        }
        _ -> {
          logger.error("No handler found with id: " <> id)

          actor.send(reply_with, Error(Nil))

          actor.continue(state)
        }
      }
    }

    ProcessClientHook(id, event, payload, reply_dispatcher) -> {
      let client_hook = case state.reconciled {
        Some(reconciled) -> {
          let hook =
            find_reconciled_hook(reconciled, fn(hook) {
              case hook {
                context.Client(i, _, _) -> unique.to_string(i) == id
                _ -> False
              }
            })

          option.to_result(hook, Nil)
        }
        None -> {
          logger.error(
            "Runtime must be reconciled before processing client hooks",
          )

          Error(Nil)
        }
      }

      case client_hook {
        Ok(Client(_id, _name, handle_event)) -> {
          option.map(handle_event, fn(handle_event) {
            handle_event(event, payload, reply_dispatcher)
          })

          actor.continue(state)
        }
        _ -> {
          logger.error("No client hook found with id: " <> id)

          actor.continue(state)
        }
      }
    }

    UpdateHookState(hook_id, update_fn) -> {
      let updated =
        state.reconciled
        |> option.map(fn(node) {
          traverse_rendered_hooks(node, fn(hook) {
            case hook {
              // this operation is only applicable to State hooks
              context.State(id, _) -> {
                case id == hook_id {
                  True -> {
                    update_fn(hook)
                  }
                  False -> hook
                }
              }
              _ -> hook
            }
          })
        })

      actor.continue(State(..state, reconciled: updated))
    }

    ReconcileImmediate(reply_with) -> {
      let prev_reconciled = state.reconciled
      let view = state.ctx.view

      let #(ctx, reconciled) =
        do_reconciliation(state.ctx, view, prev_reconciled)

      actor.send(reply_with, reconciled)

      actor.continue(State(..state, ctx: ctx, reconciled: Some(reconciled)))
    }

    RenderUpdate -> {
      let prev_reconciled = state.reconciled
      let updater = state.updater
      let view = state.ctx.view

      let #(ctx, reconciled) =
        do_reconciliation(state.ctx, view, prev_reconciled)

      case prev_reconciled {
        Some(prev_reconciled) -> {
          let update = patch.create(prev_reconciled, reconciled)

          // send the rendered patch update using updater
          case updater.send(PatchUpdate(update)) {
            Ok(_) -> Nil
            Error(_) -> {
              logger.error("Failed to send update patch!")
              Nil
            }
          }
        }

        None -> {
          // this is the first render, so we send the full reconciled view instead of a patch
          case updater.send(FullUpdate(reconciled)) {
            Ok(_) -> Nil
            Error(_) -> {
              logger.error("Failed to send full reconciled view!")
              Nil
            }
          }
        }
      }

      actor.continue(State(..state, ctx: ctx, reconciled: Some(reconciled)))
    }
  }
}

/// Start a new runtime actor
pub fn start(
  view: Element,
  updater: Updater(RenderedUpdate),
  dispatcher: Option(Dispatcher),
) -> Result(Runtime, StartError) {
  let init = fn() {
    let self = process.new_subject()
    let render_update = fn() {
      logger.debug("actor.send RenderUpdate")

      actor.send(self, RenderUpdate)
    }
    let update_hook = fn(id, updater) {
      logger.debug("actor.send UpdateHookState")

      actor.send(self, UpdateHookState(id, updater))
    }

    let assert Ok(cuid_channel) =
      cuid.start()
      |> result.map_error(fn(error) {
        logger.error("runtime.start: error starting cuid process")
        error
      })

    let state =
      State(
        ctx: context.new(
          view,
          cuid_channel,
          dispatcher,
          render_update,
          update_hook,
        ),
        updater: updater,
        reconciled: None,
        cuid_channel: cuid_channel,
      )

    let selector = process.selecting(process.new_selector(), self, identity)

    actor.Ready(state, selector)
  }

  actor.start_spec(Spec(init, call_timeout, handle_message))
}

/// Stop a runtime actor
pub fn stop(actor) {
  logger.debug("actor.send Shutdown")

  actor.send(actor, Shutdown)
}

/// Get the previously reconciled state from the actor. This is useful for testing.
pub fn get_reconciled(actor) {
  logger.debug("process.try_call GetReconciled")

  case process.try_call(actor, GetReconciled(_), call_timeout) {
    Ok(rendered) -> rendered
    Error(err) -> {
      logger.error("Error getting rendered view from runtime actor")
      io.debug(err)
      panic
    }
  }
}

/// Get the event handler for a given id
pub fn process_event(actor, id: String, payload: Option(String)) {
  logger.debug("process.try_call ProcessEvent")

  actor.send(actor, ProcessEvent(id, payload))
}

pub fn process_event_immediate(
  actor,
  id: String,
  payload: Option(String),
) -> Result(Nil, Nil) {
  logger.debug("process.try_call ProcessEventImmediate")

  case
    process.try_call(actor, ProcessEventImmediate(_, id, payload), call_timeout)
  {
    Ok(result) -> result
    Error(err) -> {
      logger.error("Error processing event from runtime actor")
      io.debug(err)
      Error(Nil)
    }
  }
}

/// Get the client hook for a given id
pub fn process_client_hook(
  actor,
  id: String,
  event: String,
  payload: Option(Dynamic),
  reply_dispatcher: fn(String, Option(String)) -> Result(Nil, Nil),
) {
  logger.debug("process.try_call GetClientHook")

  actor.send(actor, ProcessClientHook(id, event, payload, reply_dispatcher))
}

pub fn render_update(actor) {
  logger.debug("actor.send RenderUpdate")

  actor.send(actor, RenderUpdate)
}

/// Reconcile the view - should only be used for testing purposes
pub fn reconcile_immediate(actor) -> ReconciledElement {
  logger.debug("process.try_call Reconcile")

  case process.try_call(actor, ReconcileImmediate(_), call_timeout) {
    Ok(reconciled) -> reconciled
    Error(err) -> {
      logger.error("Error reconciling view from runtime actor")
      io.debug(err)
      panic
    }
  }
}

fn do_reconciliation(
  ctx: Context,
  view: Element,
  prev: Option(ReconciledElement),
) -> #(Context, ReconciledElement) {
  timer.timed_operation("runtime.reconcile", fn() {
    let ReconciledResult(ctx, reconciled) =
      ctx
      |> context.prepare_for_reconciliation
      |> recursive.reconcile(view, None, prev)

    option.map(prev, fn(prev) {
      run_cleanup_for_disposed_hooks(prev, reconciled)
    })

    // hooks might contain effects that will trigger a rerender. That is okay because any
    // RenderUpdate messages sent during this operation will be placed into this actor's mailbox
    // and will be processed in order after this current render is complete
    let reconciled = run_effects(reconciled)

    #(ctx, reconciled)
  })
}

fn cleanup_hooks(rendered: ReconciledElement) {
  // cleanup hooks
  build_hooks_map(rendered, dict.new())
  |> dict.values()
  |> list.each(fn(hook) {
    case hook {
      Effect(_, _, _, prev) -> {
        case prev {
          Some(EffectResult(Some(cleanup), _)) -> cleanup()
          _ -> Nil
        }
      }

      Reducer(_, _, cleanup) -> cleanup()

      _ -> Nil
    }
  })
}

fn run_cleanup_for_disposed_hooks(
  prev_rendered: ReconciledElement,
  rendered: ReconciledElement,
) {
  let prev_hooks = build_hooks_map(prev_rendered, dict.new())
  let new_hooks = build_hooks_map(rendered, dict.new())

  let removed_hooks =
    prev_hooks
    |> dict.keys()
    |> list.filter(fn(id) { !dict.has_key(new_hooks, id) })

  // cleanup removed hooks
  removed_hooks
  |> list.each(fn(id) {
    case dict.get(prev_hooks, id) {
      Ok(Effect(_, _, _, prev)) -> {
        case prev {
          Some(EffectResult(Some(cleanup), _)) -> cleanup()
          _ -> Nil
        }
      }

      Ok(Reducer(_, _, cleanup)) -> cleanup()

      _ -> Nil
    }
  })
}

fn build_hooks_map(
  node: ReconciledElement,
  acc: Dict(Unique, Hook),
) -> Dict(Unique, Hook) {
  case node {
    ReconciledComponent(_fc, _key, _props, hooks, el) -> {
      // add hooks from this node
      let acc =
        ordered_map.fold(hooks, acc, fn(acc, hook) {
          let KeyedItem(_, hook) = hook
          case hook {
            Callback(id, _, _) -> {
              dict.insert(acc, id, hook)
            }
            Memo(id, _, _) -> {
              dict.insert(acc, id, hook)
            }
            Handler(id, _) -> {
              dict.insert(acc, id, hook)
            }
            Effect(id, _, _, _) -> {
              dict.insert(acc, id, hook)
            }
            Reducer(id, _, _) -> {
              dict.insert(acc, id, hook)
            }
            context.State(id, _) -> {
              dict.insert(acc, id, hook)
            }
            context.Client(id, _, _) -> {
              dict.insert(acc, id, hook)
            }
          }
        })

      // add hooks from child element
      build_hooks_map(el, acc)
    }
    ReconciledElement(_tag, _key, _hooks, children) -> {
      // add hooks from children
      list.fold(children, acc, fn(acc, child) {
        dict.merge(acc, build_hooks_map(child, acc))
      })
    }
    ReconciledFragment(_key, children) -> {
      // add hooks from children
      list.fold(children, acc, fn(acc, child) {
        dict.merge(acc, build_hooks_map(child, acc))
      })
    }
    _ -> acc
  }
}

fn run_effects(rendered: ReconciledElement) -> ReconciledElement {
  process_state_hooks(rendered, fn(hook) {
    case hook {
      Effect(id, effect_fn, deps, prev) -> {
        let result = run_effect(effect_fn, deps, prev)

        Effect(id, effect_fn, deps, Some(result))
      }
      other -> other
    }
  })
}

fn run_effect(
  effect_fn: fn() -> EffectCleanup,
  deps: HookDependencies,
  prev: Option(EffectResult),
) -> EffectResult {
  // only trigger the update on the first render and when the dependencies change
  case prev {
    Some(EffectResult(cleanup, Some(prev_deps))) -> {
      case compare_deps(prev_deps, deps) {
        Changed(_) ->
          maybe_cleanup_and_rerun_effect(cleanup, effect_fn, Some(deps))
        Unchanged -> EffectResult(cleanup, Some(deps))
      }
    }

    None -> maybe_cleanup_and_rerun_effect(None, effect_fn, Some(deps))

    _ -> {
      // this should never occur and means that a hook was dynamically added
      throw_on_unexpected_hook_result(#("handle_effect", prev))
    }
  }
}

fn maybe_cleanup_and_rerun_effect(
  cleanup: EffectCleanup,
  effect_fn: fn() -> EffectCleanup,
  deps: Option(HookDependencies),
) {
  case cleanup {
    Some(cleanup_fn) -> {
      cleanup_fn()
      EffectResult(effect_fn(), deps)
    }
    _ -> EffectResult(effect_fn(), deps)
  }
}

type HookProcessor =
  fn(Hook) -> Hook

// traverse the rendered tree and process all hooks using the given function
fn process_state_hooks(
  rendered: ReconciledElement,
  process_hook: HookProcessor,
) -> ReconciledElement {
  traverse_rendered_hooks(rendered, process_hook)
}

fn find_reconciled_hook(
  node: ReconciledElement,
  find_by: fn(Hook) -> Bool,
) -> Option(Hook) {
  case node {
    ReconciledComponent(_fc, _key, _props, hooks, el) -> {
      case
        ordered_map.find(hooks, fn(keyed_item) { find_by(keyed_item.value) })
      {
        Ok(KeyedItem(_, hook)) -> Some(hook)
        _ -> {
          find_reconciled_hook(el, find_by)
        }
      }
    }
    ReconciledElement(_tag, _key, _hooks, children) -> {
      list.fold(children, None, fn(acc, child) {
        case acc {
          Some(_) -> acc
          _ -> find_reconciled_hook(child, find_by)
        }
      })
    }
    ReconciledFragment(_key, children) -> {
      list.fold(children, None, fn(acc, child) {
        case acc {
          Some(_) -> acc
          _ -> find_reconciled_hook(child, find_by)
        }
      })
    }
    _ -> None
  }
}

fn traverse_rendered_hooks(node: ReconciledElement, process_hook: HookProcessor) {
  case node {
    ReconciledComponent(fc, key, props, hooks, el) -> {
      let processed_hooks = process_hooks(hooks, process_hook)

      ReconciledComponent(
        fc,
        key,
        props,
        processed_hooks,
        traverse_rendered_hooks(el, process_hook),
      )
    }
    ReconciledElement(tag, key, hooks, children) -> {
      let r_children =
        list.fold(children, [], fn(acc, child) {
          [traverse_rendered_hooks(child, process_hook), ..acc]
        })

      ReconciledElement(tag, key, hooks, list.reverse(r_children))
    }
    ReconciledFragment(key, children) -> {
      let r_children =
        list.fold(children, [], fn(acc, child) {
          [traverse_rendered_hooks(child, process_hook), ..acc]
        })

      ReconciledFragment(key, list.reverse(r_children))
    }
    _ -> node
  }
}

fn process_hooks(
  hooks: ComponentHooks,
  process_hook: HookProcessor,
) -> ComponentHooks {
  let #(r_ordered, by_index, size) =
    hooks
    |> ordered_map.iter()
    |> process_next_hook(#([], dict.new(), 0), process_hook)

  ordered_map.from(list.reverse(r_ordered), by_index, size)
}

fn process_next_hook(
  iter: OrderedMapIter(Int, Hook),
  acc: #(List(KeyedItem(Int, Hook)), Dict(Int, Hook), Int),
  process_hook: HookProcessor,
) -> #(List(KeyedItem(Int, Hook)), Dict(Int, Hook), Int) {
  case ordered_map.next(iter) {
    Ok(#(iter, KeyedItem(index, hook))) -> {
      let #(ordered, by_index, size) = acc

      // for now, only effects are processed during this phase
      let updated = process_hook(hook)

      process_next_hook(
        iter,
        #(
          [KeyedItem(index, updated), ..ordered],
          dict.insert(by_index, index, updated),
          size
          + 1,
        ),
        process_hook,
      )
    }
    Error(_) -> acc
  }
}
