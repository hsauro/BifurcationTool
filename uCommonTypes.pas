unit uCommonTypes;

{ Minimal local copy for BifurcationEmbedded. uAntimonyAPI returns TModelErrorState from its
  Antimony->SBML conversion; that is the only thing this project needs from uCommonTypes, so
  this unit deliberately omits the plotting/data-file types the shared version also carries
  (which would pull in uPlotSeries etc.). Field names match the shared record exactly. }

interface

type
  TModelErrorState = record
    errMsg  : string;
    sbmlStr : string;
    ok      : Boolean;
  end;

implementation

end.
