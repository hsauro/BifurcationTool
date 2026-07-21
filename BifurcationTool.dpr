program BifurcationTool;

uses
  System.SysUtils,
  System.StartUpCopy,
  FMX.Forms,
  FMX.Skia,
  uAntimonyAPI in 'uAntimonyAPI.pas',
  uBifPlot in 'uBifPlot.pas',
  uBifResult in 'uBifResult.pas',
  uCommonTypes in 'uCommonTypes.pas',
  ufMain in 'ufMain.pas' {frmMain},
  uRR2DSimpleMatrix in '..\CommonCode\libRoadRunner\uRR2DSimpleMatrix.pas',
  uRoadRunner.API in '..\CommonCode\libRoadRunner\uRoadRunner.API.pas',
  uRoadRunner in '..\CommonCode\libRoadRunner\uRoadRunner.pas',
  uRRList in '..\CommonCode\libRoadRunner\uRRList.pas',
  uRRTypes in '..\CommonCode\libRoadRunner\uRRTypes.pas',
  ufSimPlot in 'ufSimPlot.pas';

{$R *.res}

begin
  // Startup is bracketed and logged to <exedir>\startup.log so an install failure on a machine with
  // no debugger says WHERE it died instead of the window just vanishing. The except block matters
  // most: without it an exception escaping CreateForm terminates the process with no message.
  try
    TfrmMain.StartupLog('--- start, exe=' + ParamStr(0));
    GlobalUseSkia := True;
    TfrmMain.StartupLog('skia enabled');
    Application.Initialize;
    TfrmMain.StartupLog('Application.Initialize done');
    Application.CreateForm(TfrmMain, frmMain);
    TfrmMain.StartupLog('CreateForm done');
    Application.Run;
    TfrmMain.StartupLog('Application.Run returned (normal exit)');
  except
    on E: Exception do
      TfrmMain.StartupLog('FATAL ' + E.ClassName + ': ' + E.Message);
  end;
end.
