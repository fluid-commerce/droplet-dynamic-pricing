import React from 'react';
import { createRoot } from 'react-dom/client';

interface FluidProps {
  name: string;
}

const Fluid = ({ name }: FluidProps) => {
  const [count, setCount] = React.useState(1);

  const handleClick = () => {
    setCount((count + 1) % 10);
  };

  return (
    <div className="flex flex-col gap-2 justify-center items-center h-screen">
      <div className="bg-slate-900 rounded-lg p-2">
        <i className="text-4xl fa-solid fa-droplet text-teal-400"></i>
        &nbsp;
        <i className="text-4xl fa-solid fa-droplet text-fuchsia-600"></i>
        <br />
        <i className="text-4xl fa-solid fa-droplet text-amber-300"></i>
        &nbsp;
        <i className="text-4xl fa-solid fa-droplet text-blue-600"></i>
      </div>
      <button
        onClick={handleClick}
        className="cursor-pointer border border-gray-600 rounded-md px-1 py-1 bg-slate-200 text-slate-800 hover:bg-slate-300 flex items-center gap-2"
      >
        <span>{name}</span>
        <span className="text-sm font-mono bg-slate-600 rounded-full px-2 text-white">{count}</span>
      </button>
    </div>
  );
};

const root = createRoot(document.getElementById('root') as HTMLElement);
root.render(<Fluid name="Fluid" />);
