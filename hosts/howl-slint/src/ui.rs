pub mod style;

slint::slint! {
    import { Button, LineEdit, VerticalBox, HorizontalBox } from "std-widgets.slint";

    export struct Palette {
        background: color,
        chrome: color,
        sidebar: color,
        terminal: color,
        row: color,
        hover: color,
        selected: color,
        selected-border: color,
        border: color,
        text: color,
        secondary: color,
        muted: color,
        accent: color,
        warning: color,
        badge: color,
    }

    export struct Style {
        palette: Palette,
        font-family: string,
        mono-family: string,
        body-size: length,
        small-size: length,
        caption-size: length,
        title-size: length,
        subtitle-size: length,
        symbol-size: length,
        medium-weight: int,
        bold-weight: int,
        brand-weight: int,
        padding: length,
        compact-padding: length,
        spacing: length,
        wide-spacing: length,
        tight-spacing: length,
        radius: length,
        stroke: length,
    }

    export component App inherits Window {
        in property <Style> style;
        title: "Howl Sessions";
        preferred-width: 72 * root.default-font-size;
        preferred-height: 48 * root.default-font-size;
        background: root.style.palette.background;
        default-font-family: root.style.font-family;
        default-font-size: root.style.body-size;

        in property <[string]> sessions;
        in property <int> selected-index: 0;
        in property <string> selected-title;
        in-out property <bool> show-sessions: false;
        // Portrait windows show one pane; landscape windows share the space.
        private property <bool> compact: root.width < root.height;
        callback select-session(int);

        // Fill the window without feeding responsive content back into its size.
        shell-layout := VerticalBox {
            x: 0px;
            y: 0px;
            width: parent.width;
            height: parent.height;
            padding: 0px;
            spacing: 0px;
            header := Rectangle {
                vertical-stretch: 0;
                background: root.style.palette.chrome;
                HorizontalBox {
                    padding: root.style.padding;
                    spacing: root.style.wide-spacing;
                    Text {
                        text: "HOWL";
                        color: root.style.palette.text;
                        font-weight: root.style.brand-weight;
                        font-size: root.style.title-size;
                    }
                    Text {
                        text: "Sessions";
                        color: root.style.palette.secondary;
                        horizontal-stretch: 1;
                    }
                    if root.compact: Button {
                        text: root.show-sessions ? "Terminal" : "Sessions";
                        clicked => { root.show-sessions = !root.show-sessions; }
                    }
                    preview-badge := Rectangle {
                        horizontal-stretch: 0;
                        border-radius: self.height / 2;
                        background: root.style.palette.badge;
                        HorizontalBox {
                            padding: root.style.compact-padding;
                            Text {
                                text: "UI preview";
                                color: root.style.palette.warning;
                                horizontal-alignment: center;
                                vertical-alignment: center;
                                font-size: root.style.small-size;
                            }
                        }
                    }
                }
            }

            panes := HorizontalBox {
                padding: 0px;
                spacing: root.style.stroke;
                // Catalog is replaced by the selected terminal in portrait.
                if !root.compact || root.show-sessions: Rectangle {
                    horizontal-stretch: 1;
                    background: root.style.palette.sidebar;
                    session-list := VerticalBox {
                        padding: root.style.padding;
                        spacing: root.style.spacing;
                        Text {
                            text: "SESSIONS";
                            color: root.style.palette.muted;
                            font-size: root.style.caption-size;
                            font-weight: root.style.bold-weight;
                        }
                        Text {
                            text: "Local layout previews";
                            color: root.style.palette.secondary;
                            font-size: root.style.small-size;
                        }
                        for session[index] in root.sessions: Rectangle {
                            vertical-stretch: 0;
                            border-radius: root.style.radius;
                            background: root.selected-index == index ? root.style.palette.selected : (row-input.has-hover ? root.style.palette.hover : root.style.palette.row);
                            border-width: root.style.stroke;
                            border-color: root.selected-index == index ? root.style.palette.selected-border : root.style.palette.border;
                            VerticalBox {
                                padding: root.style.padding; spacing: root.style.tight-spacing;
                                Text {
                                    text: session;
                                    color: root.style.palette.text;
                                    font-weight: root.style.medium-weight;
                                }
                                Text {
                                    text: "Preview · no running process";
                                    color: root.style.palette.secondary;
                                    font-size: root.style.caption-size;
                                }
                            }
                            row-input := TouchArea { clicked => { root.select-session(index); } }
                        }
                        Rectangle { vertical-stretch: 1; }
                        Text {
                            text: "No server connected";
                            color: root.style.palette.secondary;
                            font-size: root.style.small-size;
                        }
                    }
                }

                if !root.compact || !root.show-sessions: Rectangle {
                    horizontal-stretch: 3;
                    background: root.style.palette.background;
                    VerticalBox {
                        padding: root.style.padding;
                        spacing: root.style.spacing;
                        Text {
                            text: root.selected-title;
                            color: root.style.palette.text;
                            font-size: root.style.title-size;
                            font-weight: root.style.medium-weight;
                        }
                        Text {
                            text: "Terminal";
                            color: root.style.palette.muted;
                            font-size: root.style.small-size;
                        }

                        terminal-surface := Rectangle {
                            vertical-stretch: 1;
                            border-radius: root.style.radius;
                            border-width: root.style.stroke;
                            border-color: root.style.palette.border;
                            background: root.style.palette.terminal;
                            VerticalBox {
                                padding: root.style.padding;
                                spacing: root.style.spacing;
                                Rectangle { vertical-stretch: 1; }
                                Text {
                                    text: ">_";
                                    color: root.style.palette.accent;
                                    font-size: root.style.symbol-size;
                                    font-family: root.style.mono-family;
                                    horizontal-alignment: center;
                                }
                                Text {
                                    text: "Room for your terminal";
                                    color: root.style.palette.text;
                                    font-size: root.style.subtitle-size;
                                    horizontal-alignment: center;
                                    wrap: word-wrap;
                                }
                                Text {
                                    text: "This is a layout preview.\nNo connection, output or input is live.";
                                    color: root.style.palette.muted;
                                    horizontal-alignment: center;
                                    wrap: word-wrap;
                                }
                                Rectangle { vertical-stretch: 1; }
                            }
                        }

                        input-bar := HorizontalBox {
                            spacing: root.style.spacing;
                            LineEdit {
                                placeholder-text: "Input unavailable in preview";
                                enabled: false;
                                horizontal-stretch: 1;
                            }
                            Button {
                                text: "Send";
                                enabled: false;
                            }
                        }
                    }
                }
            }
            status-bar := Rectangle {
                vertical-stretch: 0;
                background: root.style.palette.chrome;
                HorizontalBox {
                    padding: root.style.compact-padding;
                    spacing: root.style.wide-spacing;
                    Text {
                        text: "●  Not connected";
                        color: root.style.palette.secondary;
                        font-size: root.style.caption-size;
                        horizontal-stretch: 1;
                    }
                    Text {
                        text: "Slint host · preview";
                        color: root.style.palette.muted;
                        font-size: root.style.caption-size;
                    }
                }
            }
        }
    }
}
