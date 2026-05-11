import FaIcon from "@/components/FaIcon";
import { useRef, useEffect } from 'react';
import Editor, { type Monaco, type OnMount } from '@monaco-editor/react';
import { configureMonacoYaml } from 'monaco-yaml';

interface YamlEditorProps {
  value: string;
  height?: string | number;
  readOnly?: boolean;
}

export default function YamlEditor({ value, height = 400, readOnly = true }: YamlEditorProps) {
  const monacoRef = useRef<Monaco | null>(null);

  useEffect(() => {
    return () => {
      monacoRef.current = null;
    };
  }, []);

  const handleBeforeMount = (monaco: Monaco) => {
    monacoRef.current = monaco;
    
    // Configure monaco-yaml
    configureMonacoYaml(monaco, {
      enableSchemaRequest: false,
      validate: false,
    });
  };

  const handleMount: OnMount = (editor) => {
    // Additional editor configuration if needed
    editor.updateOptions({
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      folding: true,
      lineNumbers: 'on',
      renderLineHighlight: 'line',
      wordWrap: 'on',
    });
  };

  return (
    <Editor
      height={height}
      language="yaml"
      value={value}
      theme="vs-dark"
      options={{
        readOnly,
        minimap: { enabled: false },
        scrollBeyondLastLine: false,
        folding: true,
        lineNumbers: 'on',
        renderLineHighlight: 'line',
        wordWrap: 'on',
        fontSize: 13,
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, "Cascadia Code", "Consolas", monospace',
        automaticLayout: true,
        padding: { top: 12, bottom: 12 },
      }}
      beforeMount={handleBeforeMount}
      onMount={handleMount}
      loading={
        <div style={{ padding: '1rem', color: 'var(--text-muted)' }}>
          <FaIcon className="fas fa-spinner fa-spin" style={{ marginRight: '0.5rem' }} />
          Loading editor…
        </div>
      }
    />
  );
}
