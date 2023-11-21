import gleam/int
import gleam/list
import gleam/string
import gleam/option.{type Option, None, Some}
import gleam/json.{type Json}
import sprocket/render.{
  type RenderedAttribute, type RenderedElement, type Renderer, RenderedAttribute,
  RenderedClientHook, RenderedComponent, RenderedElement, RenderedEventHandler,
  RenderedText, Renderer,
}
import sprocket/internal/constants.{
  ClientHookAttrPrefix, EventAttrPrefix, KeyAttr, constant,
}

pub fn renderer() -> Renderer(Json) {
  Renderer(render: fn(el) { render(el) })
}

fn render(el: RenderedElement) -> Json {
  case el {
    RenderedElement(tag: tag, key: key, attrs: attrs, children: children) ->
      element(tag, key, attrs, children)
    RenderedComponent(children: children, ..) -> component(children)
    RenderedText(text: t) -> text(t)
  }
}

fn element(
  tag: String,
  key: Option(String),
  attrs: List(RenderedAttribute),
  children: List(RenderedElement),
) -> Json {
  let attrs =
    attrs
    |> list.flat_map(fn(attr) {
      case attr {
        RenderedAttribute(name, value) -> {
          [#(name, json.string(value))]
        }
        RenderedEventHandler(kind, id) -> {
          [
            #(
              string.concat([constant(EventAttrPrefix), "-", kind]),
              json.string(id),
            ),
          ]
        }
        RenderedClientHook(name, id) -> {
          [
            #(
              string.concat([constant(ClientHookAttrPrefix)]),
              json.string(name),
            ),
            #(
              string.concat([constant(ClientHookAttrPrefix), "-id"]),
              json.string(id),
            ),
          ]
        }
      }
    })

  let attrs = case key {
    Some(k) -> list.append(attrs, [#(constant(KeyAttr), json.string(k))])
    None -> attrs
  }

  let children =
    children
    |> list.index_map(fn(i, child) { #(int.to_string(i), render(child)) })

  [#("type", json.string(tag)), #("attrs", json.object(attrs))]
  |> list.append(children)
  |> json.object()
}

fn component(children: List(RenderedElement)) -> Json {
  let children =
    children
    |> list.index_map(fn(i, child) { #(int.to_string(i), render(child)) })

  [#("type", json.string("component"))]
  |> list.append(children)
  |> json.object()
}

fn text(t: String) -> Json {
  json.string(t)
}
