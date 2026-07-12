declare module '@monaco-editor/react' {
  import type { ComponentType, ReactNode } from 'react';
  import type { editor } from 'monaco-editor';

  export type Monaco = typeof import('monaco-editor');
  export type OnMount = (editor: editor.IStandaloneCodeEditor, monaco: Monaco) => void;

  export interface EditorProps {
    height?: string | number;
    language?: string;
    value?: string;
    theme?: string;
    options?: editor.IStandaloneEditorConstructionOptions;
    beforeMount?: (monaco: Monaco) => void;
    onMount?: OnMount;
    loading?: ReactNode;
  }

  const Editor: ComponentType<EditorProps>;
  export default Editor;
}
